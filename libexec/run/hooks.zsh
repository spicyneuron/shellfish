emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/hooks.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

sf_run_hook_control() {
  local lifecycle=$1 outcome=$2
  REPLY=$(jq -c --arg lifecycle "$lifecycle" '
    . as $outcome | .control as $control |
    if has("control_error") then error(.control_error)
    elif $lifecycle == "user_prompt_submit" then
      if $outcome.exit_code == 11 then
        if ($control == {} or
            ($control.action == "handoff" and ($control | keys) == ["action","argv"] and
             ($control.argv | type == "array" and length > 0 and all(.[]; type == "string"))) or
            ($control.action == "session_update" and ($control | keys) == ["action","patch"] and
             ($control.patch | type == "object"))) then $control
        else error("invalid control") end
      elif $control == {} then $control else error("invalid control") end
    elif $lifecycle == "permission_request" and $outcome.exit_code == 11 then
      if ($control.action == "allow" and ($control | keys) == ["action"]) or
          ($control.action == "deny" and
            (($control | keys) == ["action"] or
            (($control | keys) == ["action","reason"] and ($control.reason | type == "string"))))
      then $control else error("invalid control") end
    elif $control == {} then $control
    else error("invalid control") end
  ' <<<"$outcome" 2>/dev/null) || return 1
}

sf_run_hook_match() {
  local session=$1 component=$2 input_file=$3 lifecycle=$4 turn_state=$5
  shift 5
  local match_component outcome
  match_component=$(jq -c '.command=.match.command | del(.match)' <<<"$component") || return 2
  sf_hook_invoke "$session" "$SF_SESSION[runtime]" "$match_component" \
    "$SF_SESSION[cwd]" "$input_file" "$lifecycle" "$turn_state" "$@" || return 2
  outcome=$REPLY
  jq -e '.stdout == "" and .stderr == "" and .control == {} and
    (.states | length) == 0 and (.exit_code == 0 or .exit_code == 1)' \
    <<<"$outcome" >/dev/null || return 2
  jq -e '.exit_code == 0' <<<"$outcome" >/dev/null
}

# Return one decision object in REPLY after appending every accepted record.
sf_run_hooks() {
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local input_file input_json projection component command name id activity outcome record
  local state_projection control error='' decision=proceed reason='' action='' patch=''
  local action_argv='[]'
  local -a components states
  integer exit_code invoke_status match_status

  SF_RUN_HOOK_ERROR=''
  sf_scratch_file hooks input || { SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"; return 1; }
  input_file=$REPLY
  print -rn -- "$content" >"$input_file" || {
    rm -f -- "$input_file"
    SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"
    return 1
  }
  if [[ $lifecycle == (permission_request|pre_tool_use|post_tool_use) ]]; then
    input_json=$content
  else
    input_json=$(jq -cn --arg input "$content" '$input') || {
      rm -f -- "$input_file"
      return 1
    }
  fi
  projection=$(jq -c --arg lifecycle "$lifecycle" --arg input "$content" '
    .harness[$lifecycle][]? |
    (.match.pattern? // "") as $pattern |
    select($pattern == "" or ($input | test($pattern)))
  ' <<<"$SF_SESSION[runtime]") || {
    rm -f -- "$input_file"
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  components=( ${(@f)projection} )
  for component in "${components[@]}"; do
    if jq -e '.match | has("command")' <<<"$component" >/dev/null 2>&1; then
      sf_run_hook_match "$session" "$component" "$input_file" "$lifecycle" "$turn_state" "$@"
      match_status=$?
      (( match_status == 0 )) || {
        (( match_status == 1 )) && continue
        error="hook match command failed: $(jq -r '.match.command' <<<"$component")"
        break
      }
    fi
    command=$(jq -r '.command' <<<"$component") || { error="cannot inspect $lifecycle hook"; break; }
    sf_hook_name "$command"
    name=$REPLY
    sf_hook_next_id || { error='cannot allocate hook invocation ID'; break; }
    id=$REPLY
    sf_hook_activity "$lifecycle" "$id" "$name" "$command" "$input_json" \
      "$(jq -r '.running' <<<"$component")" || { error='cannot prepare hook activity'; break; }
    activity=$REPLY
    sf_run_emit "$activity" || { error='cannot emit hook activity'; break; }
    invoke_status=0
    sf_hook_invoke "$session" "$SF_SESSION[runtime]" "$component" \
      "$SF_SESSION[cwd]" "$input_file" "$lifecycle" "$turn_state" "$@" || invoke_status=$?
    if (( invoke_status )); then
      if (( invoke_status == 129 || invoke_status == 130 || invoke_status == 143 )); then
        SF_RUN[signal_status]=$invoke_status
      fi
      error=${SF_HOOK_ERROR:-cannot run $lifecycle hook}
      break
    fi
    outcome=$REPLY
    exit_code=$(jq -r '.exit_code' <<<"$outcome") || { error='cannot inspect hook result'; break; }
    state_projection=$(jq -c '.states[]' <<<"$outcome") || { error='cannot inspect hook state'; break; }
    states=( ${(@f)state_projection} )
    for record in "${states[@]}"; do
      sf_run_append "$session" "$record" || { error=$REPLY; break 2; }
    done
    if jq -e '.exit_code != 0 or .stdout != "" or .stderr != ""' <<<"$outcome" >/dev/null; then
      sf_hook_result "$lifecycle" "$id" "$name" "$command" "$input_json" "$outcome" || {
        error="hook script returned invalid result: $command"
        break
      }
      sf_run_append "$session" "$REPLY" || { error=$REPLY; break; }
    fi
    sf_run_hook_control "$lifecycle" "$outcome" || {
      error="$lifecycle hook returned invalid control: $command"
      break
    }
    control=$REPLY
    case $exit_code in
      0) ;;
      10)
        case $lifecycle in
          user_prompt_submit) decision=handled ;;
          permission_request|pre_tool_use) decision=deny ;;
          stop) decision=continue ;;
          *) error="$lifecycle hook returned unsupported status" ;;
        esac
        ;;
      11)
        case $lifecycle in
          user_prompt_submit)
            decision=handled
            action=$(jq -r '.action // empty' <<<"$control")
            [[ $action != handoff ]] || action_argv=$(jq -c '.argv' <<<"$control")
            [[ $action != session_update ]] || patch=$(jq -c '.patch' <<<"$control")
            ;;
          permission_request)
            action=$(jq -r '.action' <<<"$control")
            [[ $decision == deny ]] || decision=$action
            reason=$(jq -r '.reason // empty' <<<"$control")
            ;;
          pre_tool_use) decision=deny ;;
          stop) decision=continue ;;
          *) error="$lifecycle hook returned unsupported status" ;;
        esac
        [[ -n $error ]] || break
        ;;
      *) error="hook script failed with status $exit_code: $command" ;;
    esac
    [[ -z $error ]] || break
  done
  rm -f -- "$input_file"
  if [[ -n $error ]]; then
    SF_RUN_HOOK_ERROR=$error
    return 1
  fi
  REPLY=$(jq -cn --arg decision "$decision" --arg action "$action" \
    --arg reason "$reason" --argjson argv "$action_argv" --argjson patch "${patch:-null}" '
      {decision:$decision} +
      (if $action == "" then {} else {action:$action} end) +
      (if $reason == "" then {} else {reason:$reason} end) +
      (if $action == "handoff" then {argv:$argv}
       elif $action == "session_update" then {patch:$patch} else {} end)
    ')
}
