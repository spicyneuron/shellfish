zmodload zsh/datetime
zmodload zsh/zselect

# Poll client input, then apply the default once its countdown ends. These
# locals belong to sf_run_permission, and review hooks poll through it too.
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
      (hold)
        permission_held=1
        sf_run_permission_countdown deny '' "$SF_RUN[user_approval_timeout]" || return 1 ;;
      (approve|approve_session|deny)
        permission_decision=$choice
        [[ $choice != deny ]] || permission_reason='sandbox access denied by user'
        return 1 ;;
    esac
  done
  (( ! SF_RUN[signal_status] )) || { permission_error='permission request interrupted'; return 1; }
  (( EPOCHREALTIME >= permission_deadline )) || return 0
  permission_decision=$permission_default
  permission_reason=${permission_default_reason:-sandbox access approval timed out}
  return 1
}

# Apply DEFAULT with REASON after SECONDS unless the client answers first.
sf_run_permission_countdown() {
  permission_default=$1 permission_default_reason=$2
  (( permission_deadline = EPOCHREALTIME + $3 ))
  sf_run_emit "$(jq -cn --arg id "$permission_id" --arg decision "$1" --argjson timeout "$3" '
    {type:"_tool_permission_update",id:$id,decision:$decision,timeout:$timeout}')" ||
    { permission_error='cannot emit permission update'; return 1; }
}

# The client and review hooks race under one countdown. It starts on deny,
# switches to a reviewer verdict for ten seconds, and returns to deny for the
# full timeout once the user takes control. A client answer always applies at
# once and cancels unfinished hooks.
sf_run_permission() {
  local session=$1 turn_state=$2 permission_id='' permission_decision=''
  local permission_reason='' permission_error='' permission_default=deny
  local permission_default_reason='' request
  float permission_deadline=$(( EPOCHREALTIME + SF_RUN[user_approval_timeout] ))
  integer permission_closed=$(( ! SF_RUN[jsonl] )) permission_held=0 reviewing=0
  local -A review
  (( SF_RUN[permission_count] += 1 ))
  permission_id="permission_$SF_RUN[permission_count]"
  [[ " $SF_RUN[lifecycles] " != *' permission_request '* ]] || reviewing=1
  # Reviewers judge the same resolved access the client shows.
  request=$(jq -c --argjson access "$SF_TOOL_PLAN[access]" \
    --arg reason "$SF_TOOL_PLAN[permission_reason]" \
    '.sandbox_access = $access + {reason:$reason}' <<<"$SF_TOOL_PLAN[request]") ||
    { sf_fail 'cannot prepare permission request'; return; }
  sf_run_emit "$(jq -cn --arg id "$permission_id" --arg name "$SF_TOOL_PLAN[name]" \
    --argjson input "$SF_TOOL_PLAN[execution_input]" --arg reason "$SF_TOOL_PLAN[permission_reason]" \
    --argjson access "$SF_TOOL_PLAN[access]" --argjson reviewing $reviewing \
    --argjson timeout "$SF_RUN[user_approval_timeout]" '
      {type:"_tool_permission_request",id:$id,tool:{name:$name,input:$input},
       access:$access,reason:$reason,timeout:$timeout,reviewing:($reviewing == 1)}')" || return 1
  {
    if (( reviewing )) && sf_run_permission_poll; then
      if sf_run_hooks --poll sf_run_permission_poll "$session" permission_request \
          "$request" "$turn_state" "$SF_TOOL_PLAN[name]" "$SF_TOOL_PLAN[id]"; then
        review=( "${reply[@]}" )
      elif [[ -z $permission_decision && -z $permission_error ]]; then
        (( ! SF_RUN[signal_status] && ! SF_RUN[write_failed] )) || permission_error=$SF_ERROR
        review=( action '' reason 'Review failed; waiting for your decision.' )
      fi
      # An answer that arrived with the verdict still wins.
      if [[ -z $permission_decision && -z $permission_error ]] && sf_run_permission_poll; then
        [[ $review[action] != deny || -n $review[reason] ]] ||
          review[reason]='sandbox access denied by permission_request hook'
        sf_run_emit "$(jq -cn --arg id "$permission_id" --arg decision "$review[action]" \
          --arg reason "$review[reason]" '
            {type:"_tool_permission_review",id:$id,decision:$decision,reason:$reason}')" ||
          permission_error='cannot emit permission review'
        if [[ -n $review[action] && -z $permission_error ]] && (( ! permission_held )); then
          sf_run_permission_countdown "$review[action]" "$review[reason]" 10
        fi
      fi
    fi
    while [[ -z $permission_decision && -z $permission_error ]]; do
      sf_run_permission_poll || break
      if (( permission_closed )); then
        permission_decision=$permission_default
        permission_reason=${permission_default_reason:-no client to approve sandbox access}
        break
      fi
      zselect -t 10 2>/dev/null || true
    done
  } always {
    sf_run_emit "$(jq -cn --arg id "$permission_id" '{type:"_tool_permission_end",id:$id}')" ||
      permission_error='cannot end permission request'
  }
  (( ! SF_RUN[signal_status] )) || return $SF_RUN[signal_status]
  [[ -z $permission_error ]] || { sf_fail "$permission_error"; return; }
  reply=( "$permission_decision" "$permission_reason" )
}

# Resolve requested paths before review and ask only for access not already
# granted to this tool. Unrestricted execution always needs a fresh decision.
sf_run_access_prepare() {
  [[ $(jq -r '.unrestricted // false' <<<"$SF_TOOL_PLAN[access]") != true ]] || return 0
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
      --args "${paths[@]}" <<<"$access") || { sf_fail 'cannot resolve sandbox access'; return; }
  done
  SF_TOOL_PLAN[access]=$(jq -c --argjson profile "$SF_RUN[profile]" \
      --arg name "$SF_TOOL_PLAN[name]" --arg cwd "$SF_RUN[cwd]" '
    def covered($paths):
      . as $target | any($paths[];
        (if startswith("/") then . else $cwd + "/" + . end |
          reduce split("/")[] as $part ([];
            if $part == "" or $part == "." then . elif $part == ".." then .[:-1]
            else . + [$part] end) | "/" + join("/")) as $grant |
        $grant == $target or ($target | startswith(($grant | rtrimstr("/")) + "/")));
    ($profile.sandbox.tools[$name] // {}) as $policy |
    {read:($policy.filesystem.allowRead // []), write:($policy.filesystem.allowWrite // []),
      domains:($policy.network.allowedDomains // [])} as $grants |
    .read |= map(select(covered($grants.read + $grants.write) | not)) |
    .write |= map(select(covered($grants.write) | not)) |
    .domains |= map(. as $target | select(any($grants.domains[]; . as $grant |
      . == "*" or . == $target or (startswith("*.") and ($target | endswith($grant[1:])))) | not))
  ' <<<"$access") || { sf_fail 'cannot inspect sandbox access'; return; }
  if jq -e 'all(.[]; length == 0)' <<<"$SF_TOOL_PLAN[access]" >/dev/null; then
    SF_TOOL_PLAN[access_status]=covered
  fi
}

# Extend this call and keep its access when approved for the session.
sf_run_access_grant() {
  local session=$1 authorization=$2 access=$SF_TOOL_PLAN[access] config
  SF_TOOL_PLAN[policy]=$(jq -c --argjson access "$access" '
    .filesystem.allowRead = ((.filesystem.allowRead // []) + $access.read | unique) |
    .filesystem.allowWrite = ((.filesystem.allowWrite // []) + $access.write | unique) |
    .network.allowedDomains = ((.network.allowedDomains // []) + $access.domains | unique)
  ' <<<"$SF_TOOL_PLAN[policy]") || { sf_fail 'cannot resolve sandbox access'; return; }
  [[ $authorization == session ]] || return 0
  config=$(jq -c --arg name "$SF_TOOL_PLAN[name]" --argjson policy "$SF_TOOL_PLAN[policy]" \
      --argjson model "$SF_RUN[model]" '
    .sandbox.tools[$name] = $policy |
    {profile:., model:$model}
  ' <<<"$SF_RUN[profile]") || { sf_fail 'cannot keep sandbox access'; return; }
  sf_run_update "$session" "$config" || return
  SF_RUN[profile]=$(jq -c .profile <<<"$config")
}

# reply holds none or the settled access, followed by any refusal outcome.
sf_run_authorize() {
  local session=$1 turn_state=$2 authorization outcome=''
  case $SF_TOOL_PLAN[access_status] in
    (none) reply=( none ); return 0 ;;
    (invalid)
      sf_run_tool_refused "$SF_TOOL_PLAN[permission_reason]" 126
      reply=( denied "$REPLY" )
      return 0 ;;
  esac
  sf_run_access_prepare || return 1
  if [[ $SF_TOOL_PLAN[access_status] == covered ]]; then
    authorization=session
  else
    sf_run_component_draft "$SF_TOOL_PLAN[component]" ||
      { sf_fail 'cannot emit tool draft'; return; }
    sf_run_permission "$session" "$turn_state" || return 1
    case $reply[1] in
      (approve) authorization=approved ;;
      (approve_session) authorization=session ;;
      (deny)
        authorization=denied
        sf_run_tool_refused "$reply[2]" 126
        outcome=$(jq -c '.output.stdout |= "<sandbox_notice>\nSandbox access denied. The tool was not run.\nReason: \(.)\n</sandbox_notice>"' <<<"$REPLY") ||
          { sf_fail 'cannot decode tool result'; return; } ;;
    esac
    if [[ $authorization != denied ]]; then
      if [[ $(jq -r '.unrestricted // false' <<<"$SF_TOOL_PLAN[access]") == true ]]; then
        SF_TOOL_PLAN[sandbox]=false
      else
        sf_run_access_grant "$session" "$authorization" || return 1
      fi
    fi
  fi
  SF_TOOL_PLAN[component]=$(jq -c --arg authorization "$authorization" '
    .draft.sandbox_access = $authorization
  ' <<<"$SF_TOOL_PLAN[component]") ||
    { sf_fail 'cannot settle sandbox access request'; return; }
  reply=( "$authorization" "$outcome" )
}
