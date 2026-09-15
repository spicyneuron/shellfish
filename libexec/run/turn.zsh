emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_session_begin_turn] )) || source "$SF_ROOT/lib/session/main.zsh"
(( $+functions[sf_hooks_user_prompt_submit] )) || source "$SF_ROOT/libexec/run/hooks.zsh"
(( $+functions[sf_tools_load] )) || source "$SF_ROOT/libexec/run/tools.zsh"
(( $+functions[sf_request_run] )) || source "$SF_ROOT/lib/request.zsh"
(( $+functions[sf_process_stop] )) || source "$SF_ROOT/lib/process.zsh"

typeset -gA SF_RUN=(
  jsonl 0 interrupted 0 signal_status 143
)

sf_run_emit() {
  (( SF_RUN[jsonl] )) && print -r -- "$1"
  return 0
}

sf_run_interrupt() {
  SF_RUN[interrupted]=1
  if [[ -n $SF_REQUEST[pid] ]]; then
    sf_process_stop "$SF_REQUEST[pid]" "$SF_REQUEST[group_file]"
    SF_REQUEST[pid]=''
  fi
}

sf_run_partial_assistant() {
  REPLY=''
  (( ${#SF_REQUEST_PARTIAL_EVENTS} )) || return 0
  REPLY=$({
    printf '%s\n' "${SF_REQUEST_PARTIAL_EVENTS[@]}"
    print -r -- '{"type":"_assistant_end","stop":"length"}'
  } | sf_jq -cse '
    include "lib/runtime/schema";
    include "lib/session/read";
    include "lib/request";
    assemble_backend_response(canonical_backend_response_events; canonical_response) |
    select(any(.content[]; (.type == "text" or .type == "reasoning") and .text != "")) |
    .stop = "cancelled"
  ' 2>/dev/null) || REPLY=''
}

# zsh defers a trap's pending exit until this cleanup call returns.
sf_run_turn_cleanup() {
  local session=$1
  integer interrupted=$2
  local failure=$3 after=$4 error_message recovered='' closed='' partial=''

  sf_hooks_turn_state_cleanup
  [[ -z $SF_REQUEST[directory] ]] ||
    rm -rf -- "$SF_REQUEST[directory]" 2>/dev/null || true
  if { (( interrupted )) || [[ -n $failure ]] } && (( ${#SF_SESSION_RECORDS} )); then
    sf_run_partial_assistant
    partial=$REPLY
    if [[ -n $partial ]]; then
      if sf_session_append "$session" "$partial"; then
        recovered=$partial
      else
        failure=$SF_SESSION_ERROR
      fi
    fi
    if (( ! interrupted )); then
      error_message=$failure
    elif (( SF_RUN[signal_status] == 130 )); then
      error_message='Cancelled.'
    else
      error_message='Turn interrupted.'
    fi
    # Close from the durable view; the interrupted in-memory view is not trusted.
    if sf_session_resync_turn "$session" "$error_message" 1; then
      closed=$REPLY
      if [[ -n $REPLY ]]; then
        [[ -z $recovered ]] || recovered+=$'\n'
        recovered+=$REPLY
      fi
    else
      failure=$SF_SESSION_ERROR
    fi
  fi
  SF_REQUEST_PARTIAL_EVENTS=()
  [[ -z $recovered ]] || sf_run_emit "$recovered"
  sf_session_reset
  if (( interrupted )); then
    [[ -n $recovered ]] || print -r -u2 -- "$error_message"
  else
    if [[ -n $failure && -z $closed ]]; then
      print -r -u2 -- "$failure"
    fi
    [[ -n $failure || -z $after ]] || sf_run_emit "$after"
    [[ -z $failure ]]
  fi
}

sf_run_turn() {
  local user_record=$1 session_path=$2 prompt=$3
  local request assistant backend_command opened_records
  local hook_action
  local runtime_projection
  local tools tool_schema fence backend_environment env_file config_dir
  local sandbox_read_paths sandbox_write_paths
  local SHELLFISH_TURN_STATE=''
  local -a runtime_fields handoff
  integer request_count=0
  integer harness_sandbox request_limit
  local failure='' after='' patch=''

  if ! sf_session_begin_turn "$session_path"; then
    print -r -u2 -- "$SF_SESSION_ERROR"
    return 1
  fi
  opened_records=$REPLY

  {
    [[ -z $opened_records ]] || sf_run_emit "$opened_records"
    runtime_projection=$(jq -jrn --argjson runtime "$SF_SESSION[runtime]" '
      def field: ., "\u0000";
      ($runtime.backend.command | field),
      (if $runtime.harness.sandbox then "1" else "0" end | field),
      ($runtime.harness.max_requests_per_turn | tostring | field),
      ($runtime.harness.fence | field),
      ($runtime.harness.sandbox_read_paths | tojson | field),
      ($runtime.harness.sandbox_write_paths | tojson | field),
      ($runtime.harness.tools | tojson | field),
      ($runtime.backend.environment | join(" ") | field),
      ($runtime.backend.env_file | field),
      ("ok" | field)
    ' 2>/dev/null) || {
      failure='cannot inspect frozen runtime'
      return 1
    }
    runtime_fields=( "${(@0)${runtime_projection%$'\0'}}" )
    (( ${#runtime_fields} == 10 )) && [[ $runtime_fields[10] == ok ]] || {
      failure='cannot inspect frozen runtime'
      return 1
    }
    backend_command=$runtime_fields[1]
    harness_sandbox=$runtime_fields[2]
    request_limit=$runtime_fields[3]
    fence=$runtime_fields[4]
    sandbox_read_paths=$runtime_fields[5]
    sandbox_write_paths=$runtime_fields[6]
    tools=$runtime_fields[7]
    backend_environment=$runtime_fields[8]
    env_file=$runtime_fields[9]
    config_dir=''
    [[ -z $env_file ]] || config_dir=${env_file:h}
    [[ -d $SF_SESSION[cwd] && -x $SF_SESSION[cwd] ]] || {
      failure="session working directory is unavailable: $SF_SESSION[cwd]"
      return 1
    }
    if ! sf_hooks_turn_state_create; then
      failure=$SF_HOOK_ERROR
      return 1
    fi
    if ! sf_hooks_user_prompt_submit "$session_path" "$prompt"; then
      failure=$SF_HOOK_ERROR
      return 1
    fi
    hook_action=$reply[1]
    handoff=( "${(@)reply[2,-1]}" )
    [[ $hook_action != session_update ]] || patch=$reply[2]
    if [[ $hook_action == proceed ]]; then
      if ! sf_tools_load "$tools" "$SF_SESSION[cwd]" "$harness_sandbox" "$fence" \
          "$sandbox_read_paths" "$sandbox_write_paths"; then
        failure=$SF_TOOL_ERROR
        return 1
      fi
      tool_schema=$REPLY
    fi
    case $hook_action in
      handoff)
        after=$(jq -cn --args '$ARGS.positional |
          {type:"_handoff",argv:.}' -- "${handoff[@]}") || {
          failure='cannot prepare handoff'
          return 1
        }
        return
        ;;
      session_update)
        if ! sf_session_update "$session_path" "$patch"; then
          failure=$SF_SESSION_ERROR
          return 1
        fi
        after=$(jq -cn --argjson runtime "$SF_SESSION[runtime]" \
          '{type:"_session_update",runtime:$runtime}') || {
          failure='cannot prepare session update'
          return 1
        }
        return
        ;;
      handled)
        return
        ;;
    esac
    if ! sf_session_append "$session_path" "$user_record"; then
      failure=$SF_SESSION_ERROR
      return 1
    fi
    sf_run_emit "$user_record"

    while true; do
      (( request_count += 1 ))
      if (( request_count > request_limit )); then
        failure="provider request limit reached: $request_limit"
        return 1
      fi
      request=$(printf '%s\n' "${SF_SESSION_RECORDS[@]}" |
        sf_request_build "$SF_SESSION[runtime]" "$tool_schema") || {
        failure='cannot prepare provider request'
        return 1
      }
      if ! sf_request_run "$request" "$backend_command" "$SF_SESSION[runtime]" \
          "$backend_environment" sf_run_emit; then
        failure=$SF_REQUEST[error]
        return 1
      fi
      assistant=$SF_REQUEST[assistant]
      if ! sf_session_append "$session_path" "$assistant"; then
        failure=$SF_SESSION_ERROR
        return 1
      fi
      sf_run_emit "$assistant"
      failure='turn orchestration is unavailable'
      return 1
    done
  } always {
    trap - TERM
    sf_run_turn_cleanup "$session_path" "$SF_RUN[interrupted]" "$failure" "$after"
  }
}
