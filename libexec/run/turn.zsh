emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/session.zsh"
source "$SF_ROOT/lib/profile.zsh"
source "$SF_ROOT/lib/backend.zsh"
source "$SF_ROOT/lib/scratch.zsh"
source "$SF_ROOT/libexec/run/hooks.zsh"
source "$SF_ROOT/libexec/run/tools.zsh"

typeset -gA SF_RUN=(
  answer '' assistant '' jsonl 0 permission_count 0 signal_status 0
  hook_id 1 hooks '[]' lifecycles '' tools '[]' write_failed 0
)

# The log's next effect and what that effect needs, from one reduction.
typeset -gA SF_RUN_STEP=()

# Turn limits come from the environment on every run, not the frozen profile.
sf_run_limits() {
  local name
  local -A limits=(
    SHELLFISH_MAX_REQUESTS_PER_TURN 100
    SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST 25
    SHELLFISH_MAX_CAPTURE_BYTES 32768
  )
  sf_environment_settings "${(k)limits}" || { REPLY=$SF_ENVIRONMENT_ERROR; return 1; }
  for name in ${(k)limits}; do
    limits[$name]=${SF_ENVIRONMENT_SETTINGS[$name]:-$limits[$name]}
    [[ $limits[$name] == <1-2147483647> ]] || { REPLY="$name must be a positive integer"; return 1; }
  done
  (( limits[SHELLFISH_MAX_CAPTURE_BYTES] >= 64 )) ||
    { REPLY='SHELLFISH_MAX_CAPTURE_BYTES must be at least 64'; return 1; }
  SF_RUN[max_requests]=$(( limits[SHELLFISH_MAX_REQUESTS_PER_TURN] ))
  SF_RUN[max_tool_calls]=$(( limits[SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST] ))
  SF_RUN[max_capture]=$(( limits[SHELLFISH_MAX_CAPTURE_BYTES] ))
}

sf_run_emit() {
  (( ! SF_RUN[jsonl] )) || print -r -- "$1"
}

sf_run_append() {
  local session=$1 record=$2
  (( ! SF_RUN[write_failed] )) || { REPLY='session writing has stopped'; return 1; }
  if ! sf_session_append "$session" "$record"; then
    SF_RUN[write_failed]=1
    REPLY=$SF_SESSION_ERROR
    return 1
  fi
  sf_run_emit "$record" || { REPLY='cannot emit session record'; return 1; }
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
    { REPLY="cannot read session: $session"; return 1; }
  SF_RUN_STEP=( "${reply[@]}" )
}

# End a turn early: keep any partial response, settle every pending call from
# the log with REASON, then record MESSAGE. The call a tool was running for
# keeps what its component already sent.
sf_run_settle() {
  local session=$1 message=$2 reason=$3 record
  sf_run_reduce '
    settle($log; $share; $home; $tools; $max_capture; $active; $ARGS.positional;
      $reason; $message)
  ' --rawfile log "$session" --argjson active "${SF_COMPONENT[values]:-null}" \
    --arg reason "$reason" --arg message "$message" \
    --jsonargs "${SF_BACKEND_PARTIAL_EVENTS[@]}" ||
    { REPLY='cannot settle the turn'; return 1; }
  for record in "${reply[@]}"; do
    sf_run_append "$session" "$record" || return
  done
}

# Tool and hook manifests are read once per run, so edits apply to the next.
sf_run_components() {
  local profile=$1
  sf_profile_components tools "$profile" || { REPLY=$SF_PROFILE_ERROR; return 1; }
  SF_RUN[tools]=$REPLY
  sf_profile_components hooks "$profile" || { REPLY=$SF_PROFILE_ERROR; return 1; }
  SF_RUN[hooks]=$REPLY
  SF_RUN[lifecycles]=$(jq -r '[.[].manifest.on] | unique | join(" ")' <<<"$REPLY") ||
    { REPLY='cannot group hooks'; return 1; }
}

sf_run_open() {
  local session=$1
  [[ $session == /* && -f $session && ! -L $session && -r $session ]] || {
    REPLY="invalid session path: $session"
    return 1
  }
  sf_run_step "$session" '($log | session_records) as $r | opened($r; $share; $home)' || return
  SF_RUN[profile]=$SF_RUN_STEP[profile]
  SF_RUN[model]=$SF_RUN_STEP[model]
  SF_RUN[cwd]=$SF_RUN_STEP[cwd]
  SF_RUN[turn_id]=$SF_RUN_STEP[turn_id]
  SF_RUN[hook_id]=$SF_RUN_STEP[hook_id]
  sf_run_components "$SF_RUN[profile]" || return
  [[ $SF_RUN_STEP[pending] == true ]] || return 0
  sf_run_settle "$session" 'Turn interrupted.' 'tool call outcome unknown'
}

sf_run_interrupt() {
  integer code=$1
  SF_RUN[signal_status]=$code
  [[ -z $SF_BACKEND[pid] ]] || sf_process_stop "$SF_BACKEND[pid]" "$SF_BACKEND[group_file]"
}

sf_run_permission_client() {
  local name=$1 input=$2 reason=$3 rendered=$4 response id
  (( SF_RUN[permission_count] += 1 ))
  id="permission_$SF_RUN[permission_count]"
  sf_run_emit "$(jq -cn --arg id "$id" --arg name "$name" --argjson input "$input" \
    --arg reason "$reason" --arg preview "$rendered" '
      {type:"_tool_permission_request",id:$id,tool:{name:$name,input:$input},
       reason:$reason,preview:$preview}')" || return 2
  IFS= read -r response || { REPLY='permission response is unavailable'; return 2; }
  REPLY=$(jq -r --arg id "$id" '
    select(type == "object" and .type == "_tool_permission_response" and .id == $id and
      (.decision == "approve" or .decision == "deny")) | .decision
  ' <<<"$response" 2>/dev/null) || { REPLY='invalid permission response'; return 2; }
  [[ -n $REPLY ]] || { REPLY='invalid permission response'; return 2; }
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
  local id name decision reason outcome message failure='' turn_state
  local -A hook_result completed
  integer begun=0 run_status

  {
    SF_RUN[answer]=''
    SF_RUN[assistant]=''
    SF_RUN[permission_count]=0
    SF_RUN[signal_status]=0
    SF_RUN[write_failed]=0
    sf_run_limits && sf_run_open "$session" || { print -r -u2 -- "$REPLY"; return 1; }
    begun=1
    [[ -d $SF_RUN[cwd] && -x $SF_RUN[cwd] ]] ||
      failure="session working directory is unavailable: $SF_RUN[cwd]"
    sf_scratch_directory turn || failure='cannot prepare hook turn state'
    turn_state=$REPLY
    if [[ -z $failure ]]; then
      if sf_run_hooks "$session" user_prompt_submit "$prompt" "$turn_state"; then
        hook_result=( "${reply[@]}" )
      else
        failure=$SF_RUN_HOOK_ERROR
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
            --argjson model "$SF_RUN[model]" '{profile:$profile,model:$model}') &&
            sf_session_update "$session" "$config" || failure=${SF_SESSION_ERROR:-invalid session update}
          if [[ -z $failure ]]; then
            sf_run_emit "$(jq -c '{type:"_session_update"} + .' <<<"$config")" && return 0
            failure='cannot emit session update'
          fi
          ;;
        block) return 0 ;;
      esac
    fi
    if [[ -z $failure ]]; then
      sf_run_append "$session" "$user_record" || failure=$REPLY
    fi
    while [[ -z $failure ]] && (( ! SF_RUN[signal_status] )); do
      sf_run_step "$session" || { failure=$REPLY; break; }
      case $SF_RUN_STEP[next] in
        request)
          if (( SF_RUN_STEP[requests] >= SF_RUN[max_requests] )); then
            failure="provider request limit reached: $SF_RUN[max_requests]"
            break
          fi
          SF_BACKEND_PLAN=( request "$SF_RUN_STEP[request]"
            command "$SF_RUN_STEP[adapter]/run" cwd "$SF_RUN[cwd]" )
          context_command=$SF_RUN_STEP[adapter]/context_window
          if (( SF_RUN_STEP[requests] == 0 )) && [[ $SF_RUN_STEP[context_window] != true &&
              -f $context_command && -x $context_command ]]; then
            sf_backend_context_window "$context_command" "$SF_RUN[max_capture]" ||
              { sf_run_status $? "$SF_BACKEND[error]"; break; }
            SF_RUN[model]=$(jq -c --argjson window "$REPLY" \
              '.context_window=$window' <<<"$SF_RUN[model]") &&
              config=$(jq -cn --argjson profile "$SF_RUN[profile]" --argjson model "$SF_RUN[model]" \
                '{profile:$profile,model:$model}') || {
              failure='cannot update model context window'
              break
            }
            sf_session_update "$session" "$config" || { failure=$SF_SESSION_ERROR; break; }
            sf_run_emit "$(jq -c '{type:"_session_update"} + .' <<<"$config")" || {
              failure='cannot emit session update'
              break
            }
          fi
          sf_backend_run sf_run_emit || {
            run_status=$?
            (( ! SF_RUN[signal_status] )) || run_status=$SF_RUN[signal_status]
            sf_run_status $run_status "$SF_BACKEND[error]"
            break
          }
          sf_run_append "$session" "$REPLY" || { failure=$REPLY; break; }
          ;;
        tool)
          SF_TOOL_PLAN=( "${(@kv)SF_RUN_STEP}" )
          id=$SF_TOOL_PLAN[id] name=$SF_TOOL_PLAN[name] decision=$SF_TOOL_PLAN[decision]
          outcome=''
          sf_run_component_prepare "$session" "$SF_TOOL_PLAN[component]"
          if (( SF_TOOL_PLAN[call_index] > SF_RUN[max_tool_calls] )); then
            sf_run_tool_refused "tool call denied: per-response limit is $SF_RUN[max_tool_calls]" 126
            outcome=$REPLY
          else
            sf_run_hooks "$session" pre_tool_use "$SF_TOOL_PLAN[request]" \
              "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
            hook_result=( "${reply[@]}" )
            if [[ $hook_result[action] == deny ]]; then
              sf_run_tool_refused "${hook_result[reason]:-tool call denied by pre_tool_use hook}" 126
              outcome=$REPLY
            elif [[ -z $SF_TOOL_PLAN[executable] ]]; then
              sf_run_tool_refused "tool is not allowed: $name" 127
              outcome=$REPLY
            else
              if [[ $decision == failure ]]; then
                failure=$SF_TOOL_PLAN[permission_reason]
                break
              elif [[ $decision == deny ]]; then
                sf_run_tool_refused "$SF_TOOL_PLAN[permission_reason]" 126
                outcome=$REPLY
              elif [[ $decision == request ]]; then
                sf_run_hooks "$session" permission_request "$SF_TOOL_PLAN[request]" \
                  "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
                hook_result=( "${reply[@]}" )
                decision=$hook_result[action]
                reason=${hook_result[reason]:-sandbox bypass denied}
                if [[ -z $decision ]]; then
                  sf_run_permission_client "$name" "$SF_TOOL_PLAN[input]" \
                    "$SF_TOOL_PLAN[permission_reason]" "$SF_TOOL_PLAN[permission_preview]"
                  run_status=$?
                  if (( run_status == 2 )); then failure=$REPLY; break; fi
                  decision=$REPLY
                fi
                if [[ $decision == deny ]]; then
                  sf_run_tool_refused "$reason" 126
                  outcome=$REPLY
                fi
              fi
              if [[ -z $outcome && $SF_TOOL_PLAN[sandbox] == true && -z ${commands[fence]-} ]]; then
                sf_run_tool_refused 'sandboxing requires fence' 126
                outcome=$REPLY
              fi
              if [[ -z $outcome ]]; then
                sf_run_tool_execute "$session" ||
                  { sf_run_status $? "${SF_RUN_TOOL_ERROR:-cannot execute tool}"; break; }
                outcome=$REPLY
              fi
            fi
          fi
          sf_run_tool_complete "$SF_COMPONENT[values]" "$outcome" || { failure=$SF_RUN_TOOL_ERROR; break; }
          completed=( "${reply[@]}" )
          sf_run_component_clear || { failure='cannot clear tool draft'; break; }
          sf_run_append "$session" "$completed[result]" || { failure=$REPLY; break; }
          # The call is settled, so an interruption from here on cancels the next one.
          SF_COMPONENT=()
          sf_run_hooks "$session" post_tool_use "$completed[post_request]" \
            "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
          ;;
        user)
          # The latest response called no tools, so stop hooks may continue it.
          sf_run_hooks "$session" stop "$SF_RUN_STEP[text]" "$turn_state" \
            "$SF_RUN_STEP[requests]" || { failure=$SF_RUN_HOOK_ERROR; break; }
          hook_result=( "${reply[@]}" )
          [[ $hook_result[action] != continue ]] || continue
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
    rm -rf -- "$turn_state" 2>/dev/null
    if (( begun && SF_RUN[signal_status] )); then
      message='Turn interrupted.'
      (( SF_RUN[signal_status] != 130 )) || message='Cancelled.'
      sf_run_settle "$session" "$message" 'tool call cancelled' || true
    fi
  }
}
