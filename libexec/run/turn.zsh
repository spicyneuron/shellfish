emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/session/main.zsh"
source "$SF_ROOT/lib/request.zsh"
source "$SF_ROOT/lib/scratch.zsh"
source "$SF_ROOT/libexec/run/hooks.zsh"
source "$SF_ROOT/libexec/run/tools.zsh"

typeset -gA SF_RUN=(
  active_call '' answer '' jsonl 0 known_outcome '' permission_count 0 signal_status 0
)

sf_run_emit() {
  (( ! SF_RUN[jsonl] )) || print -r -- "$1"
}

sf_run_append() {
  local session=$1 record=$2
  sf_session_append "$session" "$record" || { REPLY=$SF_SESSION_ERROR; return 1; }
  sf_run_emit "$record" || { REPLY='cannot emit session record'; return 1; }
}

sf_run_interrupt() {
  integer code=$1
  SF_RUN[signal_status]=$code
  [[ -z $SF_REQUEST[pid] ]] || sf_process_stop "$SF_REQUEST[pid]" "$SF_REQUEST[group_file]"
}

sf_run_error() {
  local session=$1 message=$2 record
  record=$(jq -cn --arg message "$message" '{type:"error",user_text:$message}') || return 1
  sf_run_append "$session" "$record"
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
    .stop="cancelled"
  ' 2>/dev/null) || REPLY=''
}

sf_run_cancel() {
  local session=$1 message partial pending projection call id name input component outcome record
  local active=$SF_RUN[active_call] known=$SF_RUN[known_outcome]
  local -a calls
  message='Turn interrupted.'
  (( SF_RUN[signal_status] != 130 )) || message='Cancelled.'
  sf_run_partial_assistant
  partial=$REPLY
  if [[ -n $partial ]]; then
    sf_session_append "$session" "$partial" && sf_run_emit "$partial"
  fi
  projection=$(printf '%s\n' "${SF_SESSION_RECORDS[@]:1}" | sf_jq -sc '
    include "lib/session/read";
    session_run | .calls[]
  ' 2>/dev/null) || projection=''
  calls=( ${(@f)projection} )
  for call in "${calls[@]}"; do
    id=$(jq -r '.id' <<<"$call") || continue
    name=$(jq -r '.name' <<<"$call") || continue
    input=$(jq -c '.input' <<<"$call") || continue
    if sf_run_tool_component "$SF_SESSION[runtime]" "$name"; then
      component=$REPLY
    else
      component=''
    fi
    if [[ $id == $active && -n $known ]]; then
      outcome=$known
    elif [[ $id == $active ]]; then
      sf_run_tool_refused 'tool call interrupted' 126
      outcome=$REPLY
    else
      sf_run_tool_refused 'tool call cancelled' 126
      outcome=$REPLY
    fi
    sf_run_tool_record "$id" "$name" "$input" "$component" "$outcome" || continue
    record=$REPLY
    sf_session_append "$session" "$record" && sf_run_emit "$record"
  done
  sf_run_error "$session" "$message" || true
}

sf_run_context_window() {
  local session=$1 request=$2 command=$3 selected=$4 max_capture=$5
  local directory input output window patch event name
  local -a arguments process
  sf_environment_prepare "$SF_SESSION[runtime]" "$selected" || return 1
  sf_scratch_create backends context || return 1
  directory=$REPLY
  input="$directory.input"
  print -r -- "$request" >"$input" || { rm -rf -- "$directory" "$input"; return 1; }
  arguments=()
  for name in $SF_ENVIRONMENT_NAMES; do arguments+=( -u "$name" ); done
  arguments+=( "${SF_ENVIRONMENT_VALUES[@]}" "$command" )
  if sf_process_run "$directory" "$PWD" "${input:A}" "$max_capture" \
      /usr/bin/env "${arguments[@]}"; then
    process=( "${reply[@]}" )
    if (( process[2] )); then
      SF_RUN[signal_status]=$process[1]
    elif (( process[1] == 0 )); then
      output=$(<"$directory/stdout")
      window=$(sf_jq -ser '
        include "lib/runtime/schema";
        select(length == 1 and (.[0] | type == "object" and keys == ["context_window"] and
          (.context_window | positive_integer))) | .[0].context_window
      ' <<<"$output" 2>/dev/null) || window=''
    fi
  fi
  rm -rf -- "$directory" "$input"
  (( ! SF_RUN[signal_status] )) || return $SF_RUN[signal_status]
  if [[ -n $window ]]; then
    patch=$(jq -cn --argjson window "$window" '{profile:{context_window:$window}}') || return 1
  else
    patch='{"profile":{"context_window":null}}'
  fi
  sf_session_update "$session" "$patch" || return 1
  event=$(jq -cn --argjson runtime "$SF_SESSION[runtime]" '{type:"_session_update",runtime:$runtime}') || return 1
  sf_run_emit "$event"
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

sf_run_turn() {
  local user_record=$1 session=$2 prompt=$3 opened runtime tools backend selected context_command
  local request assistant stop_text hook component call id name input activity permission decision
  local call_projection tool_request post_request
  local reason outcome state_projection record post_error='' failure='' turn_state tool_temp=''
  local -a calls states
  integer begun=0 request_count=0 call_count=0 request_limit tool_limit max_capture run_status

  {
    SF_RUN[answer]=''
    SF_RUN[active_call]=''
    SF_RUN[known_outcome]=''
    SF_RUN[permission_count]=0
    SF_RUN[signal_status]=0
    sf_session_begin_turn "$session" || { print -r -u2 -- "$SF_SESSION_ERROR"; return 1; }
    begun=1
    opened=$REPLY
    [[ -z $opened ]] || sf_run_emit "$opened"
    runtime=$SF_SESSION[runtime]
    request_limit=$(jq -r '.harness.max_requests_per_turn' <<<"$runtime") || failure='cannot inspect frozen runtime'
    tool_limit=$(jq -r '.harness.max_tool_calls_per_request' <<<"$runtime") || failure='cannot inspect frozen runtime'
    max_capture=$(jq -r '.harness.max_capture_bytes' <<<"$runtime") || failure='cannot inspect frozen runtime'
    backend=$(jq -r '.backend.command' <<<"$runtime") || failure='cannot inspect frozen runtime'
    selected=$(jq -r '.backend.environment | join(" ")' <<<"$runtime") || failure='cannot inspect frozen runtime'
    context_command=$(jq -r '.backend.context_window_command // ""' <<<"$runtime") || failure='cannot inspect frozen runtime'
    [[ -z $failure && -d $SF_SESSION[cwd] && -x $SF_SESSION[cwd] ]] ||
      failure=${failure:-session working directory is unavailable: $SF_SESSION[cwd]}
    sf_scratch_create turns turn || failure='cannot prepare hook turn state'
    turn_state=$REPLY
    if [[ -z $failure ]]; then
      sf_run_hooks "$session" user_prompt_submit "$prompt" "$turn_state" || failure=$SF_RUN_HOOK_ERROR
      hook=$REPLY
    fi
    if [[ -z $failure ]]; then
      case $(jq -r '.action // empty' <<<"$hook") in
        handoff)
          sf_run_emit "$(jq -c '{type:"_handoff",argv}' <<<"$hook")"
          return 0
          ;;
        session_update)
          sf_session_update "$session" "$(jq -c '.patch' <<<"$hook")" || failure=$SF_SESSION_ERROR
          [[ -n $failure ]] || sf_run_emit "$(jq -cn --argjson runtime "$SF_SESSION[runtime]" \
            '{type:"_session_update",runtime:$runtime}')"
          [[ -z $failure ]]
          return
          ;;
      esac
      if [[ $(jq -r '.decision' <<<"$hook") == handled ]]; then
        return 0
      fi
    fi
    if [[ -z $failure ]]; then
      sf_run_tools_schema "$runtime" || failure=$SF_RUN_TOOL_ERROR
      tools=$REPLY
      sf_scratch_create tooltemps turn || failure='cannot prepare tool temporary directory'
      tool_temp=$REPLY
    fi
    if [[ -z $failure ]]; then
      sf_run_append "$session" "$user_record" || failure=$REPLY
    fi
    while [[ -z $failure ]]; do
      (( request_count += 1 ))
      if (( request_count > request_limit )); then
        failure="provider request limit reached: $request_limit"
        break
      fi
      request=$(printf '%s\n' "${SF_SESSION_RECORDS[@]}" |
        sf_request_build "$runtime" "$tools") || { failure='cannot prepare provider request'; break; }
      if (( request_count == 1 )) && [[ -n $context_command ]] &&
          ! jq -e '.profile | has("context_window")' <<<"$runtime" >/dev/null; then
        sf_run_context_window "$session" "$request" "$context_command" "$selected" "$max_capture"
        run_status=$?
        if (( run_status )); then
          (( run_status == 129 || run_status == 130 || run_status == 143 )) ||
            failure='cannot discover model context window'
          break
        fi
        runtime=$SF_SESSION[runtime]
        request=$(printf '%s\n' "${SF_SESSION_RECORDS[@]}" |
          sf_request_build "$runtime" "$tools") || { failure='cannot prepare provider request'; break; }
      fi
      sf_request_run "$request" "$backend" "$runtime" "$selected" sf_run_emit || {
        failure=$SF_REQUEST[error]
        break
      }
      assistant=$SF_REQUEST[assistant]
      sf_run_append "$session" "$assistant" || { failure=$REPLY; break; }
      call_projection=$(jq -c '.content[] | select(.type == "tool_call")' <<<"$assistant") || {
        failure='cannot inspect provider response'
        break
      }
      calls=( ${(@f)call_projection} )
      if (( ! ${#calls} )); then
        stop_text=$(jq -r '[.content[] | select(.type == "text") | .text] | join("")' <<<"$assistant") || {
          failure='cannot inspect provider response'; break
        }
        sf_run_hooks "$session" stop "$stop_text" "$turn_state" "$request_count" || {
          failure=$SF_RUN_HOOK_ERROR
          break
        }
        hook=$REPLY
        if [[ $(jq -r '.decision' <<<"$hook") != continue ]]; then
          SF_RUN[answer]=$stop_text
          break
        fi
        continue
      fi
      call_count=0
      for call in "${calls[@]}"; do
        (( call_count += 1 ))
        id=$(jq -r '.id' <<<"$call") || { failure='cannot inspect tool call'; break; }
        name=$(jq -r '.name' <<<"$call") || { failure='cannot inspect tool call'; break; }
        input=$(jq -c '.input' <<<"$call") || { failure='cannot inspect tool call'; break; }
        tool_request=$(jq -cn --argjson turn "$SF_SESSION[turn_id]" --arg name "$name" --arg id "$id" \
          --argjson input "$input" \
          '{turn_id:$turn,tool_name:$name,tool_use_id:$id,tool_input:$input}') || {
          failure='cannot prepare tool hook input'
          break
        }
        sf_run_tool_component "$runtime" "$name"
        component=$REPLY
        sf_run_tool_activity "$id" "$name" "$input" "$component" || {
          failure='cannot prepare tool activity'; break
        }
        sf_run_emit "$REPLY" || { failure='cannot emit tool activity'; break; }
        SF_RUN[active_call]=$id
        SF_RUN[known_outcome]=''
        if (( call_count > tool_limit )); then
          sf_run_tool_refused "tool call denied: per-response limit is $tool_limit" 126
          outcome=$REPLY
        else
          sf_run_hooks "$session" pre_tool_use "$tool_request" \
            "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
          hook=$REPLY
          if [[ $(jq -r '.decision' <<<"$hook") == deny ]]; then
            sf_run_tool_refused 'tool call denied by pre_tool_use hook' 126
            outcome=$REPLY
          elif [[ -z $component ]]; then
            sf_run_tool_refused "tool is not allowed: $name" 127
            outcome=$REPLY
          else
            sf_run_tool_permission "$runtime" "$component" "$input" || { failure=$SF_RUN_TOOL_ERROR; break; }
            permission=$REPLY
            decision=$(jq -r '.decision' <<<"$permission")
            reason=$(jq -r '.reason // empty' <<<"$permission")
            if [[ $decision == failure ]]; then
              failure=$reason
              break
            elif [[ $decision == deny ]]; then
              sf_run_tool_refused "$reason" 126
              outcome=$REPLY
            elif [[ $decision == request ]]; then
              sf_run_hooks "$session" permission_request "$tool_request" \
                "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
              hook=$REPLY
              decision=$(jq -r '.decision' <<<"$hook")
              reason=$(jq -r '.reason // "sandbox bypass denied"' <<<"$hook")
              if [[ $decision == proceed ]]; then
                sf_run_tool_render "$component" "$name" "$input" \
                  '{"stdout":"","stderr":"","exit_code":0}' || { failure='cannot render permission request'; break; }
                sf_run_permission_client "$name" "$input" \
                  "$(jq -r '.reason' <<<"$permission")" "$(jq -r '.permission_text // ""' <<<"$REPLY")"
                run_status=$?
                if (( run_status == 2 )); then failure=$REPLY; break; fi
                decision=$REPLY
              fi
              if [[ $decision == deny ]]; then
                sf_run_tool_refused "$reason" 126
                outcome=$REPLY
              fi
            fi
            if [[ -z $outcome ]]; then
              sf_run_tool_execute "$session" "$runtime" "$component" "$input" "$tool_temp"
              run_status=$?
              if (( run_status )); then
                if (( run_status == 129 || run_status == 130 || run_status == 143 )); then
                  SF_RUN[signal_status]=$run_status
                else
                  failure=${SF_RUN_TOOL_ERROR:-cannot execute tool}
                fi
                break
              fi
              outcome=$REPLY
            fi
          fi
        fi
        [[ -n $outcome ]] || break
        state_projection=$(jq -c '.states[]' <<<"$outcome") || { failure='cannot inspect tool state'; break; }
        states=( ${(@f)state_projection} )
        for record in "${states[@]}"; do
          sf_run_append "$session" "$record" || { failure=$REPLY; break 2; }
        done
        SF_RUN[known_outcome]=$outcome
        post_request=$(jq -c --argjson response "$(jq -c '.output' <<<"$outcome")" \
          '. + {tool_response:$response}' <<<"$tool_request") || {
          failure='cannot prepare post-tool hook input'
          break
        }
        sf_run_hooks "$session" post_tool_use "$post_request" \
          "$turn_state" "$name" "$id" || post_error=$SF_RUN_HOOK_ERROR
        sf_run_tool_record "$id" "$name" "$input" "$component" "$outcome" || {
          failure=$SF_RUN_TOOL_ERROR; break
        }
        sf_run_append "$session" "$REPLY" || { failure=$REPLY; break; }
        SF_RUN[active_call]=''
        SF_RUN[known_outcome]=''
        outcome=''
        if [[ -n $post_error ]]; then failure=$post_error; break; fi
      done
      (( ! SF_RUN[signal_status] )) || break
    done
    if (( SF_RUN[signal_status] )); then
      return $SF_RUN[signal_status]
    fi
    if [[ -n $failure ]]; then
      sf_run_error "$session" "$failure" || true
      print -r -u2 -- "$failure"
      return 1
    fi
  } always {
    trap - TERM
    rm -rf -- "$turn_state" "$tool_temp" 2>/dev/null
    (( ! begun || ! SF_RUN[signal_status] )) || sf_run_cancel "$session"
  }
}
