emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/datetime

source "$SF_ROOT/lib/session.zsh"
source "$SF_ROOT/lib/profile.zsh"
source "$SF_ROOT/lib/provider.zsh"
source "$SF_ROOT/lib/scratch.zsh"
source "$SF_ROOT/libexec/run/hooks.zsh"
source "$SF_ROOT/libexec/run/tools.zsh"

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
  sf_environment_settings "${(k)limits}" || { REPLY=$SF_ENVIRONMENT_ERROR; return 1; }
  for name in ${(k)limits}; do
    limits[$name]=${SF_ENVIRONMENT_SETTINGS[$name]:-$limits[$name]}
    [[ $limits[$name] == <1-2147483647> ]] || { REPLY="$name must be a positive integer"; return 1; }
  done
  SF_RUN[max_requests]=$(( limits[SHELLFISH_MAX_REQUESTS_PER_TURN] ))
  SF_RUN[max_tool_calls]=$(( limits[SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST] ))
  SF_RUN[max_capture]=$(( limits[SHELLFISH_MAX_CAPTURE_KB] * 1024 ))
  SF_RUN[max_content]=$(( limits[SHELLFISH_MAX_CONTENT_KB] * 1024 ))
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
# the log with REASON, then record MESSAGE. A call whose tool had started
# settles as interrupted.
sf_run_settle() {
  local session=$1 message=$2 reason=$3 record
  sf_run_reduce '
    settle($log; $share; $home; $tools; $max_capture; $active; $ARGS.positional;
      $reason; $message)
  ' --rawfile log "$session" --argjson active "${${SF_COMPONENT[values]:+true}:-false}" \
    --arg reason "$reason" --arg message "$message" \
    --jsonargs "${SF_PROVIDER_PARTIAL_EVENTS[@]}" ||
    { REPLY='cannot settle the turn'; return 1; }
  for record in "${reply[@]}"; do
    sf_run_append "$session" "$record" || return
  done
}

# Component manifests are read once per run, so edits apply to the next.
# Commands run at user_prompt_submit. Every component reads the profile config.
sf_run_components() {
  local profile=$1
  sf_profile_components "$profile" || { REPLY=$SF_PROFILE_ERROR; return 1; }
  sf_jq_fields -cn --argjson components "$REPLY" --argjson profile "$profile" '
    include "lib/fields";
    ($components | to_entries[] | entry(.key; .value | tojson)),
    entry("config"; $profile.config // {} | tojson),
    entry("lifecycles"; $components |
      [.hooks[].manifest.on] + if .commands == [] then [] else ["user_prompt_submit"] end |
      unique | join(" ")),
    ("ok" | field)
  ' || { REPLY='cannot prepare components'; return 1; }
  SF_RUN+=( "${reply[@]}" )
}

sf_run_open() {
  local session=$1
  integer catalog_ready=${2:-0}
  [[ $session == /* && -f $session && ! -L $session && -r $session ]] || {
    REPLY="invalid session path: $session"
    return 1
  }
  sf_run_step "$session" '($log | session_records) as $r | opened($r; $share; $home)' || return
  SF_RUN[profile]=$SF_RUN_STEP[profile]
  SF_RUN[model]=$SF_RUN_STEP[model]
  SF_RUN[cwd]=$SF_RUN_STEP[cwd]
  SF_RUN[user_approval_timeout]=$SF_RUN_STEP[user_approval_timeout]
  SF_RUN[turn_id]=$SF_RUN_STEP[turn_id]
  SF_RUN[hook_id]=$SF_RUN_STEP[hook_id]
  if (( ! catalog_ready )); then
    sf_run_components "$SF_RUN[profile]" || return
  fi
  [[ $SF_RUN_STEP[pending] == true ]] || return 0
  sf_run_settle "$session" 'Turn interrupted.' 'tool call outcome unknown'
}

sf_run_interrupt() {
  integer code=$1
  SF_RUN[signal_status]=$code
  [[ -z $SF_PROVIDER[pid] ]] || sf_process_stop "$SF_PROVIDER[pid]" "$SF_PROVIDER[group_file]"
}

# Poll client input before applying any reviewer verdict or deadline. These
# locals belong to sf_run_permission; process polling keeps the same owner.
sf_run_permission_poll() {
  local response choice
  (( ! SF_RUN[write_failed] )) || { permission_error='session writing has stopped'; return 1; }
  while (( ! permission_closed )) && zselect -r 0 -t 0 >/dev/null 2>&1; do
    if ! IFS= read -r response; then permission_closed=1; break; fi
    choice=$(jq -r --arg id "$permission_id" --argjson access "$SF_TOOL_PLAN[access]" '
      if type == "object" and .type == "_tool_permission_response" and
        (.id | type == "string") and (.decision | IN("approve", "approve_session", "deny", "hold"))
      then if .id != $id then ""
        elif .decision == "approve_session" and ($access.unrestricted // false) then error
        else .decision end
      else error end
    ' <<<"$response" 2>/dev/null) || { permission_error='invalid permission response'; return 1; }
    case $choice in
      (hold) permission_hold=1 ;;
      (approve|approve_session|deny)
        permission_decision=$choice
        [[ $choice != deny ]] || permission_reason='sandbox access denied by user'
        return 1 ;;
    esac
  done
  (( ! SF_RUN[signal_status] )) || { permission_error='permission request interrupted'; return 1; }
  if [[ -n $permission_auto ]] && (( ! permission_hold &&
      (permission_closed || EPOCHREALTIME >= permission_auto_deadline) )); then
    permission_decision=$permission_auto
    permission_reason=$permission_auto_reason
    return 1
  fi
  if (( EPOCHREALTIME >= permission_deadline )); then
    permission_decision=deny permission_reason='sandbox access approval timed out'
    return 1
  fi
  return 0
}

# The prompt and hooks run together. An explicit client decision cancels an
# active hook; an untouched reviewer verdict applies ten seconds after arrival.
sf_run_permission() {
  local session=$1 turn_state=$2 permission_id='' permission_decision=''
  local permission_reason='' permission_error='' permission_auto='' permission_auto_reason=''
  float permission_deadline=0 permission_auto_deadline=0
  (( permission_deadline = EPOCHREALTIME + SF_RUN[user_approval_timeout] ))
  integer permission_closed=$(( ! SF_RUN[jsonl] )) permission_hold=0 reviewing=0
  local -A review
  (( SF_RUN[permission_count] += 1 ))
  permission_id="permission_$SF_RUN[permission_count]"
  [[ " $SF_RUN[lifecycles] " != *' permission_request '* ]] || reviewing=1
  sf_run_emit "$(jq -cn --arg id "$permission_id" --arg name "$SF_TOOL_PLAN[name]" \
    --argjson input "$SF_TOOL_PLAN[input]" --arg reason "$SF_TOOL_PLAN[permission_reason]" \
    --argjson access "$SF_TOOL_PLAN[access]" --argjson reviewing $reviewing \
    --argjson timeout "$SF_RUN[user_approval_timeout]" '
      {type:"_tool_permission_request",id:$id,tool:{name:$name,input:$input},
       access:$access,reason:$reason,timeout:$timeout,reviewing:($reviewing == 1)}')" || return 1
  {
    if sf_run_permission_poll; then
      if sf_run_hooks --poll sf_run_permission_poll "$session" permission_request \
          "$SF_TOOL_PLAN[request]" "$turn_state" "$SF_TOOL_PLAN[name]" "$SF_TOOL_PLAN[id]"; then
        review=( "${reply[@]}" )
      elif [[ -z $permission_decision && -z $permission_error ]]; then
        (( ! SF_RUN[signal_status] && ! SF_RUN[write_failed] )) || permission_error=$SF_RUN_HOOK_ERROR
        review=( action '' reason 'Review failed; waiting for your decision.' )
      fi
      if [[ -z $permission_decision && -z $permission_error ]]; then
        permission_auto=$review[action]
        [[ $permission_auto != allow ]] || permission_auto=approve
        permission_auto_reason=$review[reason]
        [[ -z $permission_auto || $permission_auto != deny || -n $permission_auto_reason ]] ||
          permission_auto_reason='sandbox access denied by permission_request hook'
        (( permission_auto_deadline = EPOCHREALTIME + 10 ))
        [[ -z $permission_auto ]] || (( permission_deadline =
          permission_deadline > permission_auto_deadline ? permission_deadline : permission_auto_deadline ))
        sf_run_permission_poll || true
        if (( reviewing )) && [[ -z $permission_decision && -z $permission_error ]]; then
          sf_run_emit "$(jq -cn --arg id "$permission_id" --arg decision "$permission_auto" \
            --arg reason "$permission_auto_reason" --argjson held $permission_hold '
              {type:"_tool_permission_review",id:$id,decision:$decision,reason:$reason,
               timeout:(if $decision == "" or $held == 1 then 0 else 10 end)}')" ||
            permission_error='cannot emit permission review'
        fi
      fi
    fi
    while [[ -z $permission_decision && -z $permission_error ]]; do
      sf_run_permission_poll || break
      if (( permission_closed )); then
        permission_decision=deny permission_reason='no client to approve sandbox access'
        break
      fi
      zselect -t 10 2>/dev/null || true
    done
  } always {
    sf_run_emit "$(jq -cn --arg id "$permission_id" '{type:"_tool_permission_end",id:$id}')" ||
      permission_error='cannot end permission request'
  }
  [[ -z $permission_error ]] || { REPLY=$permission_error; return 1; }
  reply=( "$permission_decision" "$permission_reason" )
}

# Resolve requested paths before review and ask only for access not already
# granted to this tool. Unrestricted execution always needs a fresh decision.
sf_run_access_prepare() {
  [[ $SF_TOOL_PLAN[sandbox] == true ]] || return 0
  local access=$SF_TOOL_PLAN[access] kind entry
  local -a paths
  for kind in read write; do
    paths=()
    for entry in ${(f)"$(jq -r --arg kind $kind '.[$kind][]' <<<"$access")"}; do
      case $entry in
        ('~') entry=$HOME ;;
        ('~/'*) entry=$HOME/${entry#\~/} ;;
        (/*) ;;
        (*) entry=$SF_RUN[cwd]/$entry ;;
      esac
      paths+=( ${entry:A} )
    done
    access=$(jq -c --arg kind $kind '.[$kind] = $ARGS.positional' \
      --args "${paths[@]}" <<<"$access") || { REPLY='cannot resolve sandbox access'; return 1; }
  done
  SF_TOOL_PLAN[access]=$(jq -c --argjson profile "$SF_RUN[profile]" \
      --arg name "$SF_TOOL_PLAN[name]" '
    def covered($paths):
      . as $target | any($paths[]; . as $grant |
        . == $target or ($target | startswith(($grant | rtrimstr("/")) + "/")));
    ($profile.sandbox.tools[$name] // {read:[],write:[],domains:[]}) as $grants |
    .read |= map(select(covered($grants.read + $grants.write) | not)) |
    .write |= map(select(covered($grants.write) | not)) |
    .domains |= map(. as $target | select(any($grants.domains[]; . as $grant |
      . == $target or (startswith("*.") and ($target | endswith($grant[1:])))) | not))
  ' <<<"$access") || { REPLY='cannot inspect sandbox access'; return 1; }
  if jq -e 'all(.[]; length == 0)' <<<"$SF_TOOL_PLAN[access]" >/dev/null; then
    SF_TOOL_PLAN[decision]=session
    SF_TOOL_PLAN[component]=$(jq -c '.draft.sandbox_access = "session"' \
      <<<"$SF_TOOL_PLAN[component]") || { REPLY='cannot prepare sandbox access'; return 1; }
  fi
}

# Extend this call and optionally keep its approved access in the session.
sf_run_access_grant() {
  local session=$1 keep=$2 access=$SF_TOOL_PLAN[access] kind config entries
  for kind in read write; do
    entries=$(jq -r --arg kind "$kind" '.[$kind] | join("\n")' <<<"$access") ||
      { REPLY='cannot resolve sandbox access'; return 1; }
    [[ -z $entries ]] ||
      SF_TOOL_PLAN[${kind}_paths]+=${SF_TOOL_PLAN[${kind}_paths]:+$'\n'}$entries
  done
  SF_TOOL_PLAN[domains]=$(jq -c --argjson access "$access" '. + ($access.domains - .)' \
    <<<"$SF_TOOL_PLAN[domains]") || { REPLY='cannot resolve sandbox access'; return 1; }
  [[ $keep == true ]] || return 0
  config=$(jq -c --arg name "$SF_TOOL_PLAN[name]" --argjson access "$access" \
      --argjson model "$SF_RUN[model]" '
    .sandbox.tools[$name] //= {read:[], write:[], domains:[]} |
    .sandbox.tools[$name] |= with_entries(.value += ($access[.key] - .value)) |
    {profile:., model:$model}
  ' <<<"$SF_RUN[profile]") || { REPLY='cannot keep sandbox access'; return 1; }
  sf_session_update "$session" "$config" || { REPLY=$SF_SESSION_ERROR; return 1; }
  SF_RUN[profile]=$(jq -c .profile <<<"$config")
  sf_run_emit "$(jq -c '{type:"_session_update"} + .' <<<"$config")" ||
    { REPLY='cannot emit session update'; return 1; }
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
  local id name decision outcome message failure='' turn_state keep
  local -A hook_result completed
  integer begun=0 run_status catalog_ready=${4:-0}

  {
    SF_RUN[answer]=''
    SF_RUN[assistant]=''
    SF_RUN[permission_count]=0
    SF_RUN[signal_status]=0
    SF_RUN[write_failed]=0
    sf_run_limits && sf_run_open "$session" $catalog_ready || { print -r -u2 -- "$REPLY"; return 1; }
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
        deny) return 0 ;;
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
          SF_PROVIDER_PLAN=( request "$SF_RUN_STEP[request]"
            command "$SF_RUN_STEP[provider]/run" cwd "$SF_RUN[cwd]" )
          context_command=$SF_RUN_STEP[provider]/context_window
          if (( SF_RUN_STEP[requests] == 0 )) && [[ $SF_RUN_STEP[context_window] != true &&
              -f $context_command && -x $context_command ]]; then
            sf_provider_context_window "$context_command" "$SF_RUN[max_capture]" ||
              { sf_run_status $? "$SF_PROVIDER[error]"; break; }
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
          sf_provider_run sf_run_emit || {
            run_status=$?
            (( ! SF_RUN[signal_status] )) || run_status=$SF_RUN[signal_status]
            sf_run_status $run_status "$SF_PROVIDER[error]"
            break
          }
          sf_run_append "$session" "$REPLY" || { failure=$REPLY; break; }
          ;;
        tool)
          SF_TOOL_PLAN=( "${(@kv)SF_RUN_STEP}" )
          id=$SF_TOOL_PLAN[id] name=$SF_TOOL_PLAN[name] decision=$SF_TOOL_PLAN[decision]
          outcome=''
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
              if [[ $decision == request ]]; then
                sf_run_access_prepare || { failure=$REPLY; break; }
                decision=$SF_TOOL_PLAN[decision]
              fi
              if [[ $decision == deny ]]; then
                sf_run_tool_refused "$SF_TOOL_PLAN[permission_reason]" 126
                outcome=$REPLY
              elif [[ $decision == request ]]; then
                sf_run_component_draft "$SF_TOOL_PLAN[component]" ||
                  { failure='cannot emit tool draft'; break; }
                sf_run_permission "$session" "$turn_state" || { failure=$REPLY; break; }
                decision=$reply[1]
                hook_result[reason]=$reply[2]
                if [[ $decision == deny ]]; then
                  sf_run_tool_refused \
                    "${hook_result[reason]:-sandbox access denied by permission_request hook}" 126
                  outcome=$REPLY
                  decision=denied
                # A requested bypass leaves the call unsandboxed and is never kept.
                elif [[ $SF_TOOL_PLAN[sandbox] == false ]]; then
                  decision=approved
                else
                  keep=false
                  [[ $decision != approve_session ]] || keep=true
                  sf_run_access_grant "$session" $keep || { failure=$REPLY; break; }
                  decision=approved
                  [[ $keep == false ]] || decision=session
                fi
                SF_TOOL_PLAN[component]=$(jq -c --arg decision "$decision" \
                  '.draft.sandbox_access = $decision' <<<"$SF_TOOL_PLAN[component]") ||
                  { failure='cannot settle sandbox access request'; break; }
              fi
              if [[ -z $outcome && $SF_TOOL_PLAN[sandbox] == true && -z ${commands[fence]-} ]]; then
                sf_run_tool_refused 'sandboxing requires fence' 126
                outcome=$REPLY
              fi
              if [[ -z $outcome ]]; then
                sf_run_tool_execute "$session" ||
                  { sf_run_status $? "${SF_RUN_TOOL_ERROR:-cannot execute tool}"; break; }
                outcome=$REPLY
                if [[ $decision == session ]]; then
                  outcome=$(jq -c '.output.stdout += "\n<sandbox_notice>This access is granted for the rest of this session. Later calls of this tool have it without asking. Omit request_sandbox_access for it.</sandbox_notice>"' <<<"$outcome") ||
                    { failure='cannot decode tool result'; break; }
                fi
              fi
            fi
          fi
          sf_run_tool_complete "$outcome" || { failure=$SF_RUN_TOOL_ERROR; break; }
          completed=( "${reply[@]}" )
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
    rm -rf -- "$turn_state" 2>/dev/null
    if (( begun && SF_RUN[signal_status] )); then
      message='Turn interrupted.'
      (( SF_RUN[signal_status] != 130 )) || message='Cancelled.'
      sf_run_settle "$session" "$message" 'tool call cancelled' || true
    fi
  }
}
