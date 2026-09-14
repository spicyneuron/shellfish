emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_hooks_run] )) || source "$SF_ROOT/lib/hooks.zsh"

sf_hooks_user_prompt_validate() {
  local control=$4
  integer script_status=$2
  [[ -z $control ]] || jq -e --argjson status "$script_status" '
    (keys - ["action", "argv", "patch"] | length) == 0 and
    (if has("action") then
       $status == 11 and
       (if .action == "handoff" then
          (has("patch") | not) and
          (.argv | type == "array" and length > 0 and
            (.[0] | length > 0) and
            all(.[]; type == "string" and (index("\u0000") | not)))
        elif .action == "session_update" then
          (has("argv") | not) and (.patch | type == "object")
        else false end)
     else ((has("argv") or has("patch")) | not) end)
  ' <<<$control >/dev/null || {
    SF_HOOK_ERROR='user_prompt_submit hook script returned invalid control data'
    return 1
  }
}

sf_hooks_user_prompt_submit() {
  local session=$1 prompt=$2 argument control patch
  local -a decision handoff
  integer operation_status=0 handoff_requested=0 update_requested=0

  SF_HOOK_ERROR=''
  unset SHELLFISH_TURN_ID
  SHELLFISH_TURN_ID=$SF_SESSION[turn_id]
  [[ $SHELLFISH_TURN_ID == <1-> ]] || {
    sf_hooks_fail 'cannot derive turn ID'
    unset SHELLFISH_TURN_ID
    return
  }
  export SHELLFISH_TURN_ID
  local SF_HOOK_COMPONENT_VALIDATOR=sf_hooks_user_prompt_validate
  sf_hooks_run "$session" user_prompt_submit "$prompt" allow 1 1 ||
    operation_status=1
  decision=( "${reply[@]}" )
  control=$decision[4]
  if (( ! operation_status && ! decision[1] && decision[2] )) &&
      jq -e '.action? == "handoff"' <<<"$control" >/dev/null; then
    handoff_requested=1
    while IFS= read -r -d $'\0' argument; do
      handoff+=( "$argument" )
    done < <(jq -j '.argv[] | ., "\u0000"' <<<"$control")
  elif (( ! operation_status && ! decision[1] && decision[2] )) &&
      jq -e '.action? == "session_update"' <<<"$control" >/dev/null; then
    update_requested=1
    patch=$(jq -c '.patch' <<<"$control") || operation_status=1
  fi
  if (( operation_status )); then
    [[ -n $SF_HOOK_ERROR ]] || SF_HOOK_ERROR='cannot prepare user_prompt_submit hook script invocation'
    sf_hooks_fail "$SF_HOOK_ERROR"
    unset SHELLFISH_TURN_ID
    return 1
  fi
  if (( decision[1] )); then
    typeset -g +x SHELLFISH_TURN_ID
    reply=(proceed)
  elif (( handoff_requested )); then
    unset SHELLFISH_TURN_ID
    reply=(handoff "${handoff[@]}")
  elif (( update_requested )); then
    unset SHELLFISH_TURN_ID
    reply=(session_update "$patch")
  else
    unset SHELLFISH_TURN_ID
    reply=(handled)
  fi
}

# Skipping completion requires feedback that can resume the turn.
sf_hooks_stop() {
  sf_hooks_run "$1" stop "$2" require_context 0 2 "$3" || return
  if (( reply[1] )); then reply=(finish); else reply=(continue); fi
}

sf_hooks_permission_validate() {
  local control=$4
  integer script_status=$2
  if [[ -z $control ]]; then
    (( script_status != 11 )) && return 0
    SF_HOOK_ERROR='permission_request hook script returned invalid decision'
    return 1
  fi
  (( script_status == 11 )) && jq -e '
    (keys == ["action"] and .action == "allow") or
    (keys == ["action", "reason"] and .action == "deny" and
      (.reason | type == "string" and length > 0 and
        (index("\u0000") | not)))
  ' <<<$control >/dev/null || {
    SF_HOOK_ERROR='permission_request hook script returned invalid decision'
    return 1
  }
}

sf_hooks_permission_request() {
  local session=$1 tool_name=$2 call_id=$3 tool_input=$4
  local input='' decoded
  local -a result fields
  integer operation_status=0

  SF_HOOK_ERROR=''
  if (( SF_HOOK_COUNTS[permission_request] )); then
    input=$(print -rn -- "$tool_input" | jq -c --argjson turn_id "$SHELLFISH_TURN_ID" \
      --arg tool_name "$tool_name" --arg tool_use_id "$call_id" \
      '{turn_id:$turn_id,tool_name:$tool_name,tool_use_id:$tool_use_id,
        tool_input:.}') || operation_status=1
  fi
  local SF_HOOK_COMPONENT_VALIDATOR=sf_hooks_permission_validate
  local SF_HOOK_TOOL_USE_ID=$call_id
  (( operation_status )) || sf_hooks_run "$session" permission_request "$input" allow 1 1 ||
    operation_status=1
  result=( "${reply[@]}" )
  if (( ! operation_status )); then
    if (( result[1] )); then
      reply=(defer '')
    elif (( ! result[2] )); then
      reply=(deny '')
    else
      decoded=$(jq -jr '(.action, (.reason // ""), "ok") | ., "\u0000"' \
        <<<"$result[4]") || operation_status=1
      fields=( "${(@0)${decoded%$'\0'}}" )
      (( operation_status )) || reply=( "$fields[1]" "$fields[2]" )
    fi
  fi
  if (( operation_status )); then
    [[ -n $SF_HOOK_ERROR ]] || SF_HOOK_ERROR='cannot prepare permission_request hook script invocation'
    sf_hooks_fail "$SF_HOOK_ERROR"
    return 1
  fi
}

sf_hooks_pre_tool_use() {
  local session=$1 tool_name=$2 call_id=$3 tool_input=$4 input='' origin
  local -a decision

  if (( SF_HOOK_COUNTS[pre_tool_use] )); then
    input=$(print -rn -- "$tool_input" | jq -c --argjson turn_id "$SHELLFISH_TURN_ID" \
      --arg tool_name "$tool_name" --arg tool_use_id "$call_id" \
      '{turn_id:$turn_id,tool_name:$tool_name,tool_use_id:$tool_use_id,
        tool_input:.}') || {
      sf_hooks_fail 'cannot prepare pre-tool hook input'
      return
    }
  fi
  local SF_HOOK_TOOL_USE_ID=$call_id
  sf_hooks_run "$session" pre_tool_use "$input" allow 0 1 || return
  decision=( "${reply[@]}" )
  if (( decision[1] )); then
    reply=(allow '')
  else
    # Steering belongs to the hook's own model context, not the tool result.
    origin=$decision[3]
    [[ ${origin:t} != run ]] || origin=${origin:h}
    reply=(deny "tool call denied by pre_tool_use hook: ${origin:t}")
  fi
}

# Post-tool hooks cannot skip.
sf_hooks_post_tool_use() {
  local session=$1 result=$2 tool_input=$3 input='' SF_HOOK_TOOL_USE_ID

  if (( SF_HOOK_COUNTS[post_tool_use] )); then
    input=$({ print -r -- "$tool_input"; print -r -- "$result"; } |
      jq -cs --argjson turn_id "$SHELLFISH_TURN_ID" '
        .[0] as $tool_input | .[1] as $result |
        {turn_id:$turn_id,tool_name:$result.name,tool_use_id:$result.call_id,
         tool_input:$tool_input,
         tool_response:($result | {stdout,stderr,exit_code})}
      ') || {
      sf_hooks_fail 'cannot prepare post-tool hook input'
      return
    }
  fi
  SF_HOOK_TOOL_USE_ID=$(jq -r '.call_id' <<<$result) || {
    sf_hooks_fail 'cannot prepare post-tool hook input'
    return
  }
  sf_hooks_run "$session" post_tool_use "$input" reject 0 1 || return
  reply=()
}
