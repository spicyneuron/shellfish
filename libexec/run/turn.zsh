# Bounded non-interactive execution.

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_begin_turn] )) || source "$SF_ROOT/lib/session/main.zsh"
(( $+functions[sf_runtime_resolve] )) || source "$SF_ROOT/lib/runtime/main.zsh"
(( $+functions[sf_hooks_session_start] )) || source "$SF_ROOT/lib/hooks.zsh"
(( $+functions[sf_tools_load] )) || source "$SF_ROOT/lib/tools.zsh"
(( $+functions[sf_request_run] )) || source "$SF_ROOT/lib/request.zsh"

typeset -gA SF_RUN=(
  answer '' jsonl 0 interrupted 0 permission_count 0 permission_available 0
  signal_status 143
)

sf_run_emit() {
  (( SF_RUN[jsonl] )) && print -r -- "$1"
  return 0
}

sf_run_hook_display_update() {
  local hook=$1 script=$2 text=$3 event
  if (( SF_RUN[jsonl] )); then
    event=$(print -rn -- "$text" |
      jq -Rsc --arg hook "$hook" --arg script "$script" \
        '{type:"_hook_display",hook:$hook,script:$script,text:.,complete:false}') ||
      return 1
    sf_run_emit "$event"
  fi
}

sf_run_hook_display_complete() {
  local hook=$1 script=$2 display=$3 event
  if (( ! SF_RUN[jsonl] )); then
    cat "$display" >&2
    return
  fi
  event=$(jq -cn --arg hook "$hook" --arg script "$script" --rawfile text "$display" \
    '{type:"_hook_display",hook:$hook,script:$script,text:$text,complete:true}') ||
    return 1
  sf_run_emit "$event"
}

sf_run_interrupt() {
  SF_RUN[interrupted]=1
  SF_TOOL_INTERRUPTED=1
  if [[ -n $SF_HOOK_SCRIPT_PID ]]; then
    sf_process_stop "$SF_HOOK_SCRIPT_PID"
    SF_HOOK_SCRIPT_PID=''
  fi
  if [[ -n $SF_REQUEST[pid] ]]; then
    sf_process_stop "$SF_REQUEST[pid]"
    SF_REQUEST[pid]=''
  fi
  if [[ -n $SF_TOOL_ACTIVE_PID ]]; then
    sf_process_stop "$SF_TOOL_ACTIVE_PID"
    SF_TOOL_ACTIVE_PID=''
  fi
}

# Returns 0 to allow, 1 to deny, and 2 when the decision operation failed.
sf_run_permission() {
  local call_id=$1 name=$2 input=$3 id response decision hook_decision hook_reason
  SF_RUN[permission_reason]=''
  SF_RUN[permission_error]=''
  if ! sf_hooks_permission_request "$SF_SESSION_PATH" "$name" "$call_id" "$input"; then
    SF_RUN[permission_error]=$SF_HOOK_ERROR
    return 2
  fi
  hook_decision=$reply[1]
  hook_reason=$reply[2]
  case $hook_decision in
    allow) return 0 ;;
    deny)
      SF_RUN[permission_reason]=${hook_reason:-sandbox bypass denied}
      return 1
      ;;
  esac
  if (( ! SF_RUN[permission_available] )); then
    SF_RUN[permission_reason]='sandbox bypass denied'
    return 1
  fi
  (( SF_RUN[permission_count] += 1 ))
  id="permission_$SF_RUN[permission_count]"
  jq -cn --arg id "$id" --arg call_id "$call_id" --arg name "$name" \
    --argjson input "$input" \
    '{type:"_tool_permission_request",id:$id,reason:$input.sandbox_bypass_reason,
      tool:{call_id:$call_id,name:$name,input:$input}}' || {
      SF_RUN[permission_error]='cannot prepare permission request'
      return 2
    }
  if ! IFS= read -r response; then
    decision=deny
  else
    decision=$(jq -er --arg id "$id" '
      select(type == "object" and keys == ["decision","id","type"] and
        .type == "_tool_permission_response" and .id == $id and
        (.decision | IN("approve","deny"))) | .decision
    ' <<<$response 2>/dev/null) || {
      SF_RUN[permission_error]='invalid permission response'
      return 2
    }
  fi
  if [[ $decision == approve ]]; then
    return 0
  fi
  SF_RUN[permission_reason]='sandbox bypass denied'
  return 1
}

sf_run_error() {
  if (( SF_RUN[jsonl] )); then
    sf_run_emit "$(jq -cn --arg message "$1" '{type:"_turn_error",message:$message}')"
  else
    print -r -u2 -- "$1"
  fi
}

sf_run_partial_assistant() {
  REPLY=''
  [[ -n $SF_REQUEST[partial_events] ]] || return 0
  REPLY=$({
    print -r -- "$SF_REQUEST[partial_events]"
    print -r -- '{"type":"_assistant_response_end","stop":"length"}'
  } | jq -L "$SF_ROOT" -cse '
    include "lib/runtime/schema";
    assemble_backend_response |
    select(any(.content[]; (.type == "text" or .type == "reasoning") and .text != ""))
  ' 2>/dev/null) || REPLY=''
}

# Zsh defers a trap's pending exit until this cleanup call returns.
sf_run_turn_cleanup() {
  integer interrupted=$1
  local failure=$2 after=$3 recovered='' partial=''

  sf_tools_cleanup
  sf_hooks_turn_state_cleanup
  [[ -z $SF_REQUEST[error_file] ]] ||
    rm -f -- "$SF_REQUEST[error_file]" 2>/dev/null || true
  if { (( interrupted )) || [[ -n $failure ]] } && (( ${#SF_SESSION_RECORDS} )); then
    sf_run_partial_assistant
    partial=$REPLY
    if [[ -n $partial ]]; then
      if sf_session_append "$partial"; then
        recovered=$partial
      else
        failure=$SF_SESSION_ERROR
      fi
    fi
    # An interrupted turn may have written past the in-memory view, so recovery
    # judges the durable records rather than what this process last held.
    if sf_session_resync_turn; then
      if [[ -n $REPLY ]]; then
        [[ -z $recovered ]] || recovered+=$'\n'
        recovered+=$REPLY
      fi
    else
      failure=$SF_SESSION_ERROR
    fi
  fi
  SF_REQUEST[partial_events]=''
  [[ -z $recovered ]] || sf_run_emit "$recovered"
  sf_session_reset
  if (( ! interrupted )); then
    [[ -z $failure ]] || sf_run_error "$failure"
    [[ -n $failure || -z $after ]] || sf_run_emit "$after"
    [[ -z $failure ]]
  fi
}

sf_run_turn() {
  local user_record=$1 session_path=$2 permission_available=${3:-0} prompt
  local request assistant stop_input call result backend_command opened_records
  local tool_name call_id tool_input decision denial_reason hook_action hook_reason
  local runtime_projection user_projection response_projection
  local tools tool_schema max_capture fence config_file config_dir
  local sandbox_read_paths sandbox_write_paths
  local context_output context_line context_window context_window_command update_event adapter_pid
  local SHELLFISH_TURN_STATE='' SHELLFISH_SESSION_STATE='' SF_API_KEY='' SF_API_KEY_SOURCE=''
  local -a runtime_fields user_fields response_fields tool_calls handoff
  integer request_count=0 stop_count=0 call_count tool_index
  integer harness_sandbox tool_limit request_limit context_window_set
  integer permission_status
  local failure='' after='' patch=''

  SF_RUN[permission_count]=0
  SF_RUN[permission_available]=$permission_available
  trap 'sf_run_interrupt; exit $SF_RUN[signal_status]' TERM
  if ! sf_session_begin_turn "$session_path"; then
    sf_run_error "$SF_SESSION_ERROR"
    return 1
  fi
  opened_records=$REPLY

  {
    [[ -z $opened_records ]] || sf_run_emit "$opened_records"
    runtime_projection=$(jq -jrn --argjson runtime "$SF_SESSION[runtime]" '
      def field: ., "\u0000";
      ($runtime.backend.command | field),
      (if $runtime.harness.sandbox then "1" else "0" end | field),
      ($runtime.harness.max_tool_calls_per_request | tostring | field),
      ($runtime.harness.max_requests_per_turn | tostring | field),
      ($runtime.harness.max_capture_bytes | tostring | field),
      ($runtime.harness.fence | field),
      ($runtime.harness.sandbox_read_paths | tojson | field),
      ($runtime.harness.sandbox_write_paths | tojson | field),
      ($runtime.harness.tools | tojson | field),
      ($runtime.backend.env_file | field),
      ($runtime.backend.context_window_command // "" | field),
      (if $runtime.profile | has("context_window") then "1" else "0" end | field),
      ("ok" | field)
    ' 2>/dev/null) || {
      failure='cannot inspect frozen runtime'
      return 1
    }
    runtime_fields=( "${(@0)${runtime_projection%$'\0'}}" )
    (( ${#runtime_fields} == 13 )) && [[ $runtime_fields[13] == ok ]] || {
      failure='cannot inspect frozen runtime'
      return 1
    }
    backend_command=$runtime_fields[1]
    harness_sandbox=$runtime_fields[2]
    tool_limit=$runtime_fields[3]
    request_limit=$runtime_fields[4]
    max_capture=$runtime_fields[5]
    fence=$runtime_fields[6]
    sandbox_read_paths=$runtime_fields[7]
    sandbox_write_paths=$runtime_fields[8]
    tools=$runtime_fields[9]
    config_file=$runtime_fields[10]
    context_window_command=$runtime_fields[11]
    context_window_set=$runtime_fields[12]
    config_dir=''
    [[ -z $config_file ]] || config_dir=${config_file:h}
    [[ -d $SF_SESSION[cwd] && -x $SF_SESSION[cwd] ]] || {
      failure="session working directory is unavailable: $SF_SESSION[cwd]"
      return 1
    }
    user_projection=$(jq -L "$SF_ROOT" -jnre --argjson record "$user_record" '
      include "lib/runtime/schema";
      def field: ., "\u0000";
      $record | select(canonical_user_message) |
      (tojson | field), (.content[0].text | field), ("ok" | field)
    ' 2>/dev/null) || {
      failure='exec requires a canonical user message'
      return 1
    }
    user_fields=( "${(@0)${user_projection%$'\0'}}" )
    (( ${#user_fields} == 3 )) && [[ $user_fields[3] == ok ]] || {
      failure='cannot inspect user message'
      return 1
    }
    user_record=$user_fields[1]
    prompt=$user_fields[2]
    if ! sf_hooks_turn_state_create; then
      failure=$SF_HOOK_ERROR
      return 1
    fi
    if ! sf_hooks_user_prompt_submit "$prompt" "$session_path"; then
      failure=$SF_HOOK_ERROR
      return 1
    fi
    hook_action=$reply[1]
    handoff=( "${(@)reply[2,-1]}" )
    [[ $hook_action != session_update ]] || patch=$reply[2]
    if [[ $hook_action == proceed ]]; then
      if ! sf_tools_load "$tools" "$SF_SESSION[cwd]" "$harness_sandbox" "$fence"; then
        failure=$SF_TOOL_ERROR
        return 1
      fi
      tool_schema=$REPLY
    fi
    for context in "${SF_HOOK_CONTEXT_RECORDS[@]}"; do
      if ! sf_session_append "$context"; then
        failure=$SF_SESSION_ERROR
        return 1
      fi
      sf_run_emit "$context"
    done
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
        if ! sf_session_update "$patch"; then
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
    if ! sf_session_append "$user_record"; then
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
      if (( request_count == 1 )) && ! sf_runtime_resolve_api_key "$SF_SESSION[runtime]"; then
        failure=$SF_RUNTIME_ERROR
        return 1
      fi
      if (( request_count == 1 )); then
        SF_API_KEY=$REPLY
        SF_API_KEY_SOURCE=$reply[1]
      fi
      if (( request_count == 1 && ! context_window_set )) &&
          [[ -n $context_window_command ]]; then
        context_output=''
        coproc SHELLFISH_API_KEY="$SF_API_KEY" \
          SHELLFISH_API_KEY_SOURCE="$SF_API_KEY_SOURCE" \
          "$context_window_command" <<<"$request" 2>/dev/null
        adapter_pid=$!
        SF_REQUEST[pid]=$adapter_pid
        while IFS= read -r context_line <&p; do
          [[ -z $context_output ]] || context_output+=$'\n'
          context_output+=$context_line
        done
        if ! wait "$adapter_pid"; then
          context_output=''
        fi
        SF_REQUEST[pid]=''
        context_window=$(jq -L "$SF_ROOT" -ser '
          include "lib/runtime/schema";
          select(length == 1 and (.[0] | type == "object" and
            keys == ["context_window"] and (.context_window | positive_integer))) |
          .[0].context_window
        ' <<<"$context_output" 2>/dev/null) || context_window=''
        if [[ -n $context_window ]]; then
          patch=$(jq -cn --argjson context_window "$context_window" \
            '{profile:{context_window:$context_window}}') || {
            failure='cannot prepare context window update'
            return 1
          }
          if ! sf_session_update "$patch"; then
            failure=$SF_SESSION_ERROR
            return 1
          fi
        else
          if ! sf_session_update '{"profile":{"context_window":null}}'; then
            failure=$SF_SESSION_ERROR
            return 1
          fi
        fi
        update_event=$(jq -cn --argjson runtime "$SF_SESSION[runtime]" \
          '{type:"_session_update",runtime:$runtime}') || {
          failure='cannot prepare context window update'
          return 1
        }
        sf_run_emit "$update_event"
      fi
      if ! sf_request_run "$request" "$backend_command" "$SF_API_KEY" \
          "$SF_API_KEY_SOURCE" sf_run_emit; then
        failure=$SF_REQUEST[error]
        return 1
      fi
      assistant=$SF_REQUEST[assistant]
      if ! sf_session_append "$assistant"; then
        failure=$SF_SESSION_ERROR
        return 1
      fi
      sf_run_emit "$assistant"
      response_projection=$(jq -jr '
        def field: ., "\u0000";
        (.stop | field),
        (.content[] | select(.type == "tool_call") |
          (tojson | field), (.id | field), (.name | field), (.input | tojson | field)),
        ([.content[] | select(.type == "text") | .text] | join("") | field),
        ("ok" | field)
      ' <<<"$assistant") || {
        failure='cannot inspect provider response'
        return 1
      }
      response_fields=( "${(@0)${response_projection%$'\0'}}" )
      (( ${#response_fields} >= 3 && (${#response_fields} - 3) % 4 == 0 )) &&
          [[ $response_fields[-1] == ok ]] || {
        failure='cannot inspect provider response'
        return 1
      }
      stop_input=$response_fields[-2]
      if [[ $response_fields[1] != tool_calls ]]; then
        (( stop_count += 1 ))
        if ! sf_hooks_stop "$session_path" "$stop_input" "$stop_count"; then
          failure=$SF_HOOK_ERROR
          return 1
        fi
        hook_action=$reply[1]
        if [[ $hook_action == finish ]]; then
          SF_RUN[answer]=$stop_input
          return
        fi
        sf_run_emit "${(pj:\n:)SF_SESSION_RECORDS[-SF_HOOK_CONTEXT_COUNT,-1]}"
        continue
      fi
      call_count=0
      tool_calls=( "${(@)response_fields[2,-3]}" )
      for (( tool_index = 1; tool_index <= ${#tool_calls}; tool_index += 4 )); do
        (( call_count += 1 ))
        call=$tool_calls[tool_index]
        call_id=$tool_calls[tool_index+1]
        tool_name=$tool_calls[tool_index+2]
        tool_input=$tool_calls[tool_index+3]
        if (( call_count > tool_limit )); then
          if ! sf_tool_result "$call_id" "$tool_name" \
              "tool call denied: per-response limit is $tool_limit" 126; then
            failure=${SF_TOOL_ERROR:-cannot prepare denied tool result}
            return 1
          fi
          result=$REPLY
        else
          if ! sf_hooks_pre_tool_use "$session_path" "$tool_name" "$call_id" "$tool_input"; then
            failure=$SF_HOOK_ERROR
            return 1
          fi
          hook_action=$reply[1]
          hook_reason=$reply[2]
          if [[ $hook_action == deny ]]; then
            if ! sf_tool_result "$call_id" "$tool_name" \
                "$hook_reason" \
                126; then
              failure=${SF_TOOL_ERROR:-cannot prepare denied tool result}
              return 1
            fi
            result=$REPLY
          else
            decision=''
            denial_reason=''
            sf_tool_needs_permission "$tool_name" "$tool_input" "$tools" "$harness_sandbox"
            permission_status=$?
            if (( permission_status == 0 )); then
              permission_status=0
              sf_run_permission "$call_id" "$tool_name" "$tool_input" ||
                permission_status=$?
              case $permission_status in
                0) decision=approved ;;
                1) denial_reason=$SF_RUN[permission_reason] ;;
                *)
                  failure=$SF_RUN[permission_error]
                  return 1
                  ;;
              esac
            elif (( permission_status == 2 )); then
              failure=$SF_TOOL_ERROR
              return 1
            fi
            if ! sf_tool_execute "$call" "$harness_sandbox" "$decision" "$denial_reason" \
                "$tools" "$SF_SESSION[cwd]" "$max_capture" "$fence" \
                "$sandbox_read_paths" "$sandbox_write_paths" "$config_dir" \
                "$SF_SESSION[id]"; then
              failure=${SF_TOOL_ERROR:-shell tool execution failed}
              return 1
            fi
            result=$REPLY
          fi
        fi
        if ! sf_session_append "$result"; then
          failure=$SF_SESSION_ERROR
          return 1
        fi
        sf_run_emit "$result"
        if ! sf_hooks_post_tool_use "$session_path" "$result" "$tool_input"; then
          failure=$SF_HOOK_ERROR
          return 1
        fi
      done
    done
  } always {
    trap - TERM
    sf_run_turn_cleanup "$SF_RUN[interrupted]" "$failure" "$after"
  }
}
