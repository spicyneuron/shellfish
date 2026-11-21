emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload -F zsh/files b:zf_rm

source "$SF_ROOT/lib/session.zsh"
source "$SF_ROOT/lib/profile.zsh"
source "$SF_ROOT/lib/provider.zsh"
source "$SF_ROOT/lib/scratch.zsh"
source "$SF_ROOT/libexec/run/hooks.zsh"
source "$SF_ROOT/libexec/run/tools.zsh"
source "$SF_ROOT/libexec/run/sandbox.zsh"

typeset -gA SF_RUN=(
  answer '' assistant '' jsonl 0 permission_count 0 signal_status 0
  commands '[]' hook_id 1 hooks '[]' lifecycles '' tools '[]' write_failed 0
)

# The log's next effect and what that effect needs, from one reduction.
typeset -gA SF_RUN_STEP=()

# Turn limits come from the environment on every run, not the frozen profile.
sf_run_limits() {
  local name
  local -A limits=(
    SHELLFISH_MAX_REQUESTS_PER_TURN 100
    SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST 25
    SHELLFISH_MAX_CAPTURE_KB 32
    SHELLFISH_MAX_CONTENT_KB 5120
  )
  sf_environment_settings "${(k)limits}" || return
  for name in ${(k)limits}; do
    limits[$name]=${SF_ENVIRONMENT_SETTINGS[$name]:-$limits[$name]}
    [[ $limits[$name] == <1-2147483647> ]] || { sf_fail "$name must be a positive integer"; return; }
  done
  SF_RUN[max_requests]=$(( limits[SHELLFISH_MAX_REQUESTS_PER_TURN] ))
  SF_RUN[max_tool_calls]=$(( limits[SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST] ))
  SF_RUN[max_capture]=$(( limits[SHELLFISH_MAX_CAPTURE_KB] * 1024 ))
  SF_RUN[max_content]=$(( limits[SHELLFISH_MAX_CONTENT_KB] * 1024 ))
}

sf_run_emit() {
  (( ! SF_RUN[jsonl] )) || print -r -- "$1" || sf_fail 'cannot emit turn event'
}

sf_run_append() {
  local session=$1 record=$2
  (( ! SF_RUN[write_failed] )) || { sf_fail 'session writing has stopped'; return; }
  if [[ -n ${3-} ]]; then
    record=$(jq -ce --argjson section "$3" '. + {section:$section}' <<<"$record") ||
      { sf_fail 'cannot assign section'; return; }
  fi
  if ! sf_session_append "$session" "$record"; then
    SF_RUN[write_failed]=1
    return 1
  fi
  sf_run_emit "$record" || { sf_fail 'cannot emit session record'; return; }
}

sf_run_section() {
  (( SF_RUN[next_section] <= 999999999 )) || { sf_fail 'section IDs exhausted'; return; }
  REPLY=$SF_RUN[next_section]
  (( SF_RUN[next_section] += 1 ))
}

sf_run_assistant_emit() {
  local event=$1
  if [[ $event == '{"type":"_assistant_start"}' ]]; then
    event="{\"type\":\"_assistant_start\",\"section\":$SF_RUN[agent_section]}"
  fi
  sf_run_emit "$event"
}

sf_run_update() {
  local session=$1 config=$2
  sf_session_update "$session" "$config" || return
  sf_run_emit "$(jq -c '{type:"_session_update"} + .' <<<"$config")" ||
    { sf_fail 'cannot emit session update'; return; }
}

typeset -gr SF_RUN_REDUCTIONS=$(<"$SF_ROOT/libexec/run/turn.jq")

# Run BODY after the turn's reduction definitions, into reply.
sf_run_reduce() {
  local body=$1
  shift
  # The program leads, since a trailing --jsonargs takes every later argument.
  sf_jq_fields -n "$SF_RUN_REDUCTIONS"$'\n'"$body"$'\n, ("ok" | field)' \
    --arg share "$SF_SHARE" --arg home "${HOME:+${HOME:A}}" \
    --argjson tools "$SF_RUN[tools]" --argjson max_capture "$SF_RUN[max_capture]" "$@"
}

# Reduce the log to its next effect. Before the turn, BODY reads what opening needs.
sf_run_step() {
  local session=$1
  local body=${2:-'($log | session_records) as $r | step($r; $share; $home; $tools; $max_capture)'}
  sf_run_reduce "$body" --rawfile log "$session" ||
    { sf_fail "cannot read session: $session"; return; }
  SF_RUN_STEP=( "${reply[@]}" )
}

# End a turn early: keep any partial response, settle every pending call from
# the log with REASON, then record MESSAGE. A call whose tool had started
# settles as interrupted.
sf_run_settle() {
  local session=$1 message=$2 reason=$3 record
  sf_run_reduce '
    settle($log; $share; $home; $tools; $max_capture; $active; $ARGS.positional;
      $section; $reason; $message)
  ' --rawfile log "$session" --argjson active "${${SF_COMPONENT[values]:+true}:-false}" \
    --argjson section "${SF_RUN[agent_section]:-0}" --arg reason "$reason" --arg message "$message" \
    --jsonargs "${SF_PROVIDER_PARTIAL_EVENTS[@]}" ||
    { sf_fail 'cannot settle the turn'; return; }
  for record in "${reply[@]}"; do
    sf_run_append "$session" "$record" || return
  done
}

# Component manifests are read once per run, so edits apply to the next.
# Commands run at user_prompt_submit. Every component reads the profile config.
sf_run_components() {
  local profile=$1
  sf_profile_components "$profile" || return
  sf_jq_fields -cn --argjson components "$REPLY" --argjson profile "$profile" '
    include "lib/fields";
    ($components | to_entries[] | entry(.key; .value | tojson)),
    entry("config"; $profile.config // {} | tojson),
    entry("lifecycles"; $components |
      [.hooks[].manifest.on] + if .commands == [] then [] else ["user_prompt_submit"] end |
      unique | join(" ")),
    ("ok" | field)
  ' || { sf_fail 'cannot prepare components'; return; }
  SF_RUN+=( "${reply[@]}" )
}

sf_run_open() {
  local session=$1
  integer catalog_ready=${2:-0}
  [[ $session == /* && -f $session && ! -L $session && -r $session ]] || {
    sf_fail "invalid session path: $session"
    return
  }
  sf_run_step "$session" '($log | session_records) as $r | opened($r; $share; $home)' || return
  SF_RUN[profile]=$SF_RUN_STEP[profile]
  SF_RUN[model]=$SF_RUN_STEP[model]
  SF_RUN[cwd]=$SF_RUN_STEP[cwd]
  SF_RUN[user_approval_timeout]=$SF_RUN_STEP[user_approval_timeout]
  SF_RUN[turn_id]=$SF_RUN_STEP[turn_id]
  SF_RUN[hook_id]=$SF_RUN_STEP[hook_id]
  SF_RUN[next_section]=$SF_RUN_STEP[next_section]
  SF_RUN[agent_section]=0
  if (( ! catalog_ready )); then
    sf_run_components "$SF_RUN[profile]" || return
  fi
  [[ $SF_RUN_STEP[pending] == true ]] || return 0
  SF_RUN[agent_section]=$SF_RUN_STEP[agent_section]
  if (( ! SF_RUN[agent_section] )); then
    sf_run_section || return
    SF_RUN[agent_section]=$REPLY
  fi
  sf_run_settle "$session" 'Turn interrupted.' 'tool call outcome unknown' || return
  SF_RUN[agent_section]=0
}

sf_run_interrupt() {
  integer code=$1
  SF_RUN[signal_status]=$code
  [[ -z $SF_PROVIDER[pid] ]] || sf_process_stop "$SF_PROVIDER[pid]" "$SF_PROVIDER[group_file]"
}

# A signal status, or a failure message for anything else.
sf_run_status() {
  integer code=$1
  if (( code == 129 || code == 130 || code == 143 )); then
    SF_RUN[signal_status]=$code
  else
    failure=$2
  fi
}

sf_run_turn() {
  local user_record=$1 session=$2 prompt=$3 config context_command
  local id name authorization outcome message failure='' turn_state
  local -A hook_result completed
  integer begun=0 run_status catalog_ready=${4:-0}

  {
    sf_run_open "$session" $catalog_ready || { print -r -u2 -- "$SF_ERROR"; return 1; }
    begun=1
    [[ -d $SF_RUN[cwd] && -x $SF_RUN[cwd] ]] ||
      failure="session working directory is unavailable: $SF_RUN[cwd]"
    # The limit is in bytes, so multibyte text counts in full.
    () { setopt local_options no_multibyte; (( ${#1} <= SF_RUN[max_content] )) } "$user_record" ||
      failure='user message exceeds content limit'
    sf_scratch -d turn || failure='cannot prepare hook turn state'
    turn_state=$REPLY
    if [[ -z $failure ]]; then
      if sf_run_hooks "$session" user_prompt_submit "$prompt" "$turn_state"; then
        hook_result=( "${reply[@]}" )
      else
        failure=$SF_ERROR
      fi
    fi
    if [[ -z $failure ]]; then
      case $hook_result[action] in
        handoff)
          if sf_run_emit "$(jq -cn --argjson argv "$hook_result[payload]" '{type:"_handoff",argv:$argv}')"; then
            return 0
          fi
          failure='cannot emit handoff'
          ;;
        session_update)
          config=$(jq -cn --argjson profile "$hook_result[payload]" \
            --argjson model "$SF_RUN[model]" '{profile:$profile,model:$model}') ||
            failure='invalid session update'
          if [[ -z $failure ]]; then
            sf_run_update "$session" "$config" && return 0
            failure=$SF_ERROR
          fi
          ;;
        deny) return 0 ;;
      esac
    fi
    if [[ -z $failure ]]; then
      if sf_run_section; then
        sf_run_append "$session" "$user_record" "$REPLY" || failure=$SF_ERROR
      else
        failure=$SF_ERROR
      fi
    fi
    while [[ -z $failure ]] && (( ! SF_RUN[signal_status] )); do
      sf_run_step "$session" || { failure=$SF_ERROR; break; }
      case $SF_RUN_STEP[next] in
        request)
          if (( SF_RUN_STEP[requests] >= SF_RUN[max_requests] )); then
            failure="provider request limit reached: $SF_RUN[max_requests]"
            break
          fi
          SF_PROVIDER_PLAN=( request "$SF_RUN_STEP[request]"
            command "$SF_RUN_STEP[provider]/run" cwd "$SF_RUN[cwd]" )
          context_command=$SF_RUN_STEP[provider]/context_window
          if (( SF_RUN_STEP[requests] == 0 )) && [[ $SF_RUN_STEP[context_window] != true &&
              -f $context_command && -x $context_command ]]; then
            sf_provider_context_window "$context_command" "$SF_RUN[max_capture]" ||
              { sf_run_status $? "$SF_ERROR"; break; }
            SF_RUN[model]=$(jq -c --argjson window "$REPLY" \
              '.context_window=$window' <<<"$SF_RUN[model]") &&
              config=$(jq -cn --argjson profile "$SF_RUN[profile]" --argjson model "$SF_RUN[model]" \
                '{profile:$profile,model:$model}') || {
              failure='cannot update model context window'
              break
            }
            sf_run_update "$session" "$config" || { failure=$SF_ERROR; break; }
          fi
          if (( ! SF_RUN[agent_section] )); then
            sf_run_section || { failure=$SF_ERROR; break; }
            SF_RUN[agent_section]=$REPLY
          fi
          sf_provider_run sf_run_assistant_emit || {
            run_status=$?
            (( ! SF_RUN[signal_status] )) || run_status=$SF_RUN[signal_status]
            sf_run_status $run_status "$SF_ERROR"
            break
          }
          sf_run_append "$session" "$REPLY" "$SF_RUN[agent_section]" || { failure=$SF_ERROR; break; }
          ;;
        tool)
          SF_TOOL_PLAN=( "${(@kv)SF_RUN_STEP}" )
          id=$SF_TOOL_PLAN[id] name=$SF_TOOL_PLAN[name]
          outcome=''
          if (( SF_TOOL_PLAN[call_index] > SF_RUN[max_tool_calls] )); then
            sf_run_tool_refused "tool call denied: per-response limit is $SF_RUN[max_tool_calls]" 126
            outcome=$REPLY
          else
            sf_run_hooks "$session" pre_tool_use "$SF_TOOL_PLAN[request]" \
              "$turn_state" "$name" "$id" || { failure=$SF_ERROR; break; }
            hook_result=( "${reply[@]}" )
            if [[ $hook_result[action] == deny ]]; then
              sf_run_tool_refused "${hook_result[reason]:-tool call denied by pre_tool_use hook}" 126
              outcome=$REPLY
            elif [[ -z $SF_TOOL_PLAN[executable] ]]; then
              sf_run_tool_refused "tool is not allowed: $name" 127
              outcome=$REPLY
            else
              sf_run_authorize "$session" "$turn_state" || { failure=$SF_ERROR; break; }
              authorization=$reply[1]
              if [[ $authorization == denied ]]; then
                outcome=$reply[2]
              fi
              if [[ -z $outcome && $SF_TOOL_PLAN[sandbox] == true && -z ${commands[fence]-} ]]; then
                sf_run_tool_refused 'sandboxing requires fence' 126
                outcome=$REPLY
              fi
              if [[ -z $outcome ]]; then
                sf_run_tool_execute "$session" ||
                  { sf_run_status $? "$SF_ERROR"; break; }
                outcome=$REPLY
                if [[ $authorization == session ]]; then
                  outcome=$(jq -c '.output.stdout += "\n<sandbox_notice>This access is granted for the rest of this session. Later calls of this tool have it without asking. Do not request it again.</sandbox_notice>"' <<<"$outcome") ||
                    { failure='cannot decode tool result'; break; }
                fi
              fi
            fi
          fi
          sf_run_tool_complete "$outcome" || { failure=$SF_ERROR; break; }
          completed=( "${reply[@]}" )
          sf_run_append "$session" "$completed[result]" || { failure=$SF_ERROR; break; }
          # The call is settled, so an interruption from here on cancels the next one.
          SF_COMPONENT=()
          sf_run_hooks "$session" post_tool_use "$completed[post_request]" \
            "$turn_state" "$name" "$id" || { failure=$SF_ERROR; break; }
          ;;
        user)
          # The latest response called no tools, so stop hooks may continue it.
          sf_run_hooks "$session" stop "$SF_RUN_STEP[text]" "$turn_state" \
            "$SF_RUN_STEP[requests]" || { failure=$SF_ERROR; break; }
          hook_result=( "${reply[@]}" )
          [[ $hook_result[action] != deny ]] || continue
          SF_RUN[answer]=$SF_RUN_STEP[text]
          SF_RUN[assistant]=$SF_RUN_STEP[response]
          break
          ;;
      esac
    done
    if (( SF_RUN[signal_status] )); then
      return $SF_RUN[signal_status]
    fi
    if [[ -n $failure ]]; then
      # After a failed write, nothing more can be recorded.
      (( SF_RUN[write_failed] )) || sf_run_settle "$session" "$failure" 'tool call cancelled' || true
      print -r -u2 -- "$failure"
      return 1
    fi
  } always {
    trap - TERM
    zf_rm -rf -- "$turn_state" 2>/dev/null
    if (( begun && SF_RUN[signal_status] )); then
      message='Turn interrupted.'
      (( SF_RUN[signal_status] != 130 )) || message='Cancelled.'
      sf_run_settle "$session" "$message" 'tool call cancelled' || true
    fi
  }
}
