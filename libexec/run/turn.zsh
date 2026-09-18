emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/session.zsh"
source "$SF_ROOT/lib/backend.zsh"
source "$SF_ROOT/lib/scratch.zsh"
source "$SF_ROOT/libexec/run/hooks.zsh"
source "$SF_ROOT/libexec/run/tools.zsh"

typeset -gA SF_RUN=(
  active_call '' answer '' jsonl 0 known_outcome '' permission_count 0 signal_status 0
  write_failed 0
)

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

# Settle every still-pending call through the tool owner. The reason describes
# calls the turn never reached.
sf_run_settle() {
  local session=$1 reason=$2 call outcome
  local active=$SF_RUN[active_call] known=$SF_RUN[known_outcome]
  local -a calls
  sf_jq_fields 0 -Rs '
    include "lib/session";
    def field: ., "\u0000";
    [split("\n")[1:][] | select(length > 0) | fromjson] |
    session_run |
    (.calls[] | {id,name,input} | tojson | field),
    ("ok" | field)
  ' "$session" || reply=()
  calls=( "${reply[@]}" )
  for call in "${calls[@]}"; do
    sf_run_tool_plan "$SF_RUN[runtime]" "$call" || break
    if [[ $SF_TOOL_PLAN[id] == $active && -n $known ]]; then
      outcome=$known
    elif [[ $SF_TOOL_PLAN[id] == $active ]]; then
      sf_run_tool_refused 'tool call interrupted' 126
      outcome=$REPLY
    else
      sf_run_tool_refused "$reason" 126
      outcome=$REPLY
    fi
    sf_run_tool_complete "$outcome" || break
    sf_run_append "$session" "$REPLY" || return 1
  done
}

sf_run_open() {
  local session=$1
  local -a fields
  [[ $session == /* && -f $session && ! -L $session && -r $session ]] || {
    REPLY="invalid session path: $session"
    return 1
  }
  sf_jq_fields 4 -Rs '
    include "lib/runtime";
    include "lib/session";
    def field: ., "\u0000";
    select(endswith("\n")) |
    split("\n") as $lines |
    select($lines[-1] == "" and ($lines[0:-1] | length > 0) and
      all($lines[0:-1][]; length > 0)) |
    ($lines[0:-1] | map(fromjson)) as $records |
    select($records[0] | canonical_session_header) |
    ($records[1:] | session_run) as $run |
    ($records[0].runtime | tojson | field),
    ($records[0].cwd | field),
    (([$records[1:][] | select(.type == "user")] | length + 1) | tostring | field),
    (($run.next != "user") | tostring | field),
    ("ok" | field)
  ' "$session" || {
    REPLY="cannot read session: $session"
    return 1
  }
  fields=( "${reply[@]}" )
  SF_RUN[runtime]=$fields[1]
  SF_RUN[cwd]=$fields[2]
  SF_RUN[turn_id]=$fields[3]
  [[ $fields[4] == true ]] || return 0
  sf_run_settle "$session" 'tool call outcome unknown' || return 1
  sf_run_error "$session" 'Turn interrupted.'
}

sf_run_interrupt() {
  integer code=$1
  SF_RUN[signal_status]=$code
  [[ -z $SF_BACKEND[pid] ]] || sf_process_stop "$SF_BACKEND[pid]" "$SF_BACKEND[group_file]"
}

sf_run_error() {
  local session=$1 message=$2 record
  record=$(jq -cn --arg message "$message" '{type:"error",user_text:$message}') || return 1
  sf_run_append "$session" "$record"
}

sf_run_partial_assistant() {
  REPLY=''
  (( ${#SF_BACKEND_PARTIAL_EVENTS} )) || return 0
  REPLY=$({
    printf '%s\n' "${SF_BACKEND_PARTIAL_EVENTS[@]}"
    print -r -- '{"type":"_assistant_end","stop":"length"}'
  } | sf_jq -cse '
    include "lib/session";
    include "lib/backend";
    assemble_backend_response(canonical_backend_response_events; canonical_response) |
    select(any(.content[]; (.type == "text" or .type == "reasoning") and .text != "")) |
    .stop="cancelled"
  ' 2>/dev/null) || REPLY=''
}

# Record any partial response, settle pending calls, then close the turn.
sf_run_cancel() {
  local session=$1 message partial
  message='Turn interrupted.'
  (( SF_RUN[signal_status] != 130 )) || message='Cancelled.'
  sf_run_partial_assistant
  partial=$REPLY
  if [[ -n $partial ]]; then
    sf_run_append "$session" "$partial" || return
  fi
  sf_run_settle "$session" 'tool call cancelled' || return
  sf_run_error "$session" "$message" || true
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

sf_run_project() {
  local runtime=$1
  local -a fields
  sf_jq_fields 5 -rn --argjson runtime "$runtime" '
    def field: ., "\u0000";
    $runtime.harness as $harness |
    [$harness.tools[] |
      .manifest as $manifest |
      (($harness.sandbox and $manifest.sandbox and
        ($manifest.allow_sandbox_bypass // false))) as $bypass |
      {name,description:($manifest.description +
        if $harness.sandbox and $manifest.sandbox
        then "\n\nThis tool runs under its package sandbox policy."
        else "\n\nSandboxing is disabled; this tool runs with the current user permissions." end +
        if .name == "shell" and $bypass
        then "\n\nWhen requesting an unsandboxed command, keep it to one logical operation. Split multi-step or compound commands across calls so each approval is easy to review."
        else "" end),
       input_schema:($manifest.input_schema |
         if $bypass then
           .properties.request_sandbox_bypass={type:"boolean",description:"Request approval to run without the sandbox"} |
           .properties.sandbox_bypass_reason={type:"string",minLength:1,
             description:"Explain why this tool call must run outside the sandbox"} |
           .allOf=((.allOf // []) + [{
             if:{properties:{request_sandbox_bypass:{const:true}},required:["request_sandbox_bypass"]},
             then:{required:["sandbox_bypass_reason"]}}])
         else . end)}] as $tools |
    ($harness.max_requests_per_turn | tostring | field),
    ($harness.max_tool_calls_per_request | tostring | field),
    ($harness.max_capture_bytes | tostring | field),
    ($runtime.backend.context_window_command // "" | field),
    ($tools | tojson | field),
    ("ok" | field)
  ' || return 1
  fields=( "${reply[@]}" )
  reply=( "${(@)fields[1,4]}" )
  REPLY=$fields[5]
}

sf_run_turn() {
  local user_record=$1 session=$2 prompt=$3 runtime tools context_command
  local assistant stop_text id name decision post_request
  local reason outcome record post_error='' failure='' turn_state tool_temp='' call
  local call_projection
  local -a calls states hook_result runtime_fields
  integer begun=0 request_count=0 call_count=0 request_limit tool_limit max_capture run_status

  {
    SF_RUN[answer]=''
    SF_RUN[active_call]=''
    SF_RUN[known_outcome]=''
    SF_RUN[permission_count]=0
    SF_RUN[signal_status]=0
    SF_RUN[write_failed]=0
    sf_run_open "$session" || { print -r -u2 -- "$REPLY"; return 1; }
    begun=1
    runtime=$SF_RUN[runtime]
    sf_run_project "$runtime" || failure='cannot inspect frozen runtime'
    tools=$REPLY
    runtime_fields=( "${reply[@]}" )
    request_limit=$runtime_fields[1]
    tool_limit=$runtime_fields[2]
    max_capture=$runtime_fields[3]
    context_command=$runtime_fields[4]
    [[ -z $failure && -d $SF_RUN[cwd] && -x $SF_RUN[cwd] ]] ||
      failure=${failure:-session working directory is unavailable: $SF_RUN[cwd]}
    sf_scratch_create turns turn || failure='cannot prepare hook turn state'
    turn_state=$REPLY
    if [[ -z $failure ]]; then
      sf_run_hooks "$session" user_prompt_submit "$prompt" "$turn_state" || failure=$SF_RUN_HOOK_ERROR
      hook_result=( "${reply[@]}" )
    fi
    if [[ -z $failure ]]; then
      case $hook_result[2] in
        handoff)
          if sf_run_emit "$(jq -cn --argjson argv "$hook_result[4]" '{type:"_handoff",argv:$argv}')"; then
            return 0
          fi
          failure='cannot emit handoff'
          ;;
        session_update)
          if sf_session_replace_runtime "$session" "$hook_result[4]"; then
            if sf_run_emit "$(jq -cn --argjson runtime "$hook_result[4]" \
                '{type:"_session_update",runtime:$runtime}')"; then
              return 0
            fi
            failure='cannot emit session update'
          else
            failure=$SF_SESSION_ERROR
          fi
          ;;
      esac
      if [[ -z $failure && $hook_result[1] == handled ]]; then
        return 0
      fi
    fi
    if [[ -z $failure ]]; then
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
      if (( request_count == 1 )) && [[ -n $context_command ]] &&
          ! jq -e '.profile | has("context_window")' <<<"$runtime" >/dev/null; then
        sf_backend_context_window "$tools" "$max_capture" <"$session"
        run_status=$?
        if (( run_status )); then
          if (( run_status == 129 || run_status == 130 || run_status == 143 )); then
            SF_RUN[signal_status]=$run_status
          else
            failure=$SF_BACKEND[error]
          fi
          break
        fi
        runtime=$(jq -c --argjson window "$REPLY" \
          '.profile.context_window=$window' <<<"$runtime") || {
          failure='cannot update model context window'
          break
        }
        sf_session_replace_runtime "$session" "$runtime" || { failure=$SF_SESSION_ERROR; break; }
        SF_RUN[runtime]=$runtime
        sf_run_emit "$(jq -cn --argjson runtime "$runtime" \
          '{type:"_session_update",runtime:$runtime}')" || {
          failure='cannot emit session update'
          break
        }
      fi
      sf_backend_request "$tools" sf_run_emit <"$session"
      run_status=$?
      if (( run_status )); then
        if (( SF_RUN[signal_status] )); then
          run_status=$SF_RUN[signal_status]
        fi
        if (( run_status == 129 || run_status == 130 || run_status == 143 )); then
          SF_RUN[signal_status]=$run_status
        else
          failure=$SF_BACKEND[error]
        fi
        break
      fi
      assistant=$REPLY
      sf_run_append "$session" "$assistant" || { failure=$REPLY; break; }
      call_projection=$(jq -c '.content[] | select(.type == "tool_call")' \
        <<<"$assistant") || { failure='cannot inspect provider response'; break; }
      calls=()
      [[ -z $call_projection ]] || calls=( "${(@f)call_projection}" )
      if (( ! ${#calls} )); then
        stop_text=$(jq -r '[.content[] | select(.type == "text") | .text] | join("")' <<<"$assistant") || {
          failure='cannot inspect provider response'; break
        }
        sf_run_hooks "$session" stop "$stop_text" "$turn_state" "$request_count" || {
          failure=$SF_RUN_HOOK_ERROR
          break
        }
        hook_result=( "${reply[@]}" )
        if [[ $hook_result[1] != continue ]]; then
          SF_RUN[answer]=$stop_text
          break
        fi
        continue
      fi
      call_count=0
      for call in "${calls[@]}"; do
        (( call_count += 1 ))
        sf_run_tool_plan "$runtime" "$call" || { failure=$SF_RUN_TOOL_ERROR; break; }
        id=$SF_TOOL_PLAN[id]
        name=$SF_TOOL_PLAN[name]
        decision=$SF_TOOL_PLAN[decision]
        sf_run_emit "$SF_TOOL_PLAN[activity]" || { failure='cannot emit tool activity'; break; }
        SF_RUN[active_call]=$id
        SF_RUN[known_outcome]=''
        if (( call_count > tool_limit )); then
          sf_run_tool_refused "tool call denied: per-response limit is $tool_limit" 126
          outcome=$REPLY
        else
          sf_run_hooks "$session" pre_tool_use "$SF_TOOL_PLAN[request]" \
            "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
          hook_result=( "${reply[@]}" )
          if [[ $hook_result[1] == deny ]]; then
            sf_run_tool_refused 'tool call denied by pre_tool_use hook' 126
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
              decision=$hook_result[1]
              reason=${hook_result[3]:-sandbox bypass denied}
              if [[ $decision == proceed ]]; then
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
            if [[ -z $outcome ]]; then
              sf_run_tool_execute "$session" "$tool_temp"
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
        sf_run_tool_complete "$outcome" || { failure=$SF_RUN_TOOL_ERROR; break; }
        record=$REPLY
        post_request=$reply[1]
        states=( "${(@)reply[2,-1]}" )
        for record in "${states[@]}"; do
          sf_run_append "$session" "$record" || { failure=$REPLY; break 2; }
        done
        SF_RUN[known_outcome]=$outcome
        sf_run_hooks "$session" post_tool_use "$post_request" \
          "$turn_state" "$name" "$id" || post_error=$SF_RUN_HOOK_ERROR
        sf_run_append "$session" "$record" || { failure=$REPLY; break; }
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
