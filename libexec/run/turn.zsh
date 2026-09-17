emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/session.zsh"
source "$SF_ROOT/lib/backend.zsh"
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

sf_run_cancel() {
  local session=$1 message partial projection record
  local active=$SF_RUN[active_call] known=$SF_RUN[known_outcome]
  local -a records
  message='Turn interrupted.'
  (( SF_RUN[signal_status] != 130 )) || message='Cancelled.'
  sf_run_partial_assistant
  partial=$REPLY
  if [[ -n $partial ]]; then
    sf_session_append "$session" "$partial" && sf_run_emit "$partial"
  fi
  projection=$(printf '%s\n' "${SF_SESSION_RECORDS[@]:1}" | sf_jq -jsc \
    --argjson runtime "$SF_SESSION[runtime]" --arg active "$active" \
    --argjson known "${known:-null}" '
    include "lib/session";
    include "lib/runtime";
    def field: ., "\u0000";
    session_run | .calls[] |
    . as $call |
    ([$runtime.harness.tools[] | select(.name == $call.name)][0]) as $tool |
    ($tool.manifest.render // tool_render_defaults) as $render |
    (if $call.id == $active and $known != null then $known
     else {output:{stdout:"",stderr:"",exit_code:126},states:[],
       reason:(if $call.id == $active then "tool call interrupted" else "tool call cancelled" end)} end) as $outcome |
    render_component($render;$call.name;$call.input;
      ($outcome.output + if $outcome | has("reason") then {stderr:$outcome.reason} else {} end)) as $rendered |
    ({type:"tool_result",id:$call.id,name:$call.name,input:$call.input,
      exit_code:$outcome.output.exit_code} +
     (if $tool == null then {} else {executable:$tool.command} end) +
     (if $rendered.user_text == null then {} else {user_text:$rendered.user_text} end) +
     (if $rendered.model_text == null then {} else {model_text:($rendered.model_text +
       if $outcome.sandbox_denied then "\n\n<sandbox_notice>A denial was detected during this tool call. This does not necessarily mean the tool failed.</sandbox_notice>"
       else "" end)} end)) |
    select(canonical_tool_result) | tojson | field
  ' 2>/dev/null) || projection=''
  records=()
  [[ -z $projection ]] || records=( "${(@0)${projection%$'\0'}}" )
  for record in "${records[@]}"; do
    sf_session_append "$session" "$record" && sf_run_emit "$record"
  done
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
  local runtime=$1 projected
  local -a fields
  projected=$(jq -jrn --argjson runtime "$runtime" '
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
  ' 2>/dev/null) || return 1
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} == 6 )) && [[ $fields[6] == ok ]] || return 1
  reply=( "${(@)fields[1,4]}" )
  REPLY=$fields[5]
}

sf_run_turn() {
  local user_record=$1 session=$2 prompt=$3 opened runtime tools context_command
  local assistant stop_text id name input decision
  local tool_request post_request activity permission_reason permission_preview executable render
  local tool_environment settings fence env_file execution_input sandbox read_paths write_paths
  local reason outcome state_projection record post_error='' failure='' turn_state tool_temp='' call
  local call_projection call_projected
  local -a calls call_fields states hook_result runtime_fields tool_plan
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
    sf_run_project "$runtime" || failure='cannot inspect frozen runtime'
    tools=$REPLY
    runtime_fields=( "${reply[@]}" )
    request_limit=$runtime_fields[1]
    tool_limit=$runtime_fields[2]
    max_capture=$runtime_fields[3]
    context_command=$runtime_fields[4]
    [[ -z $failure && -d $SF_SESSION[cwd] && -x $SF_SESSION[cwd] ]] ||
      failure=${failure:-session working directory is unavailable: $SF_SESSION[cwd]}
    sf_scratch_create turns turn || failure='cannot prepare hook turn state'
    turn_state=$REPLY
    if [[ -z $failure ]]; then
      sf_run_hooks "$session" user_prompt_submit "$prompt" "$turn_state" || failure=$SF_RUN_HOOK_ERROR
      hook_result=( "${reply[@]}" )
    fi
    if [[ -z $failure ]]; then
      case $hook_result[2] in
        handoff)
          sf_run_emit "$(jq -cn --argjson argv "$hook_result[4]" '{type:"_handoff",argv:$argv}')"
          return 0
          ;;
        session_update)
          sf_session_update "$session" "$hook_result[4]" || failure=$SF_SESSION_ERROR
          [[ -n $failure ]] || sf_run_emit "$(jq -cn --argjson runtime "$SF_SESSION[runtime]" \
            '{type:"_session_update",runtime:$runtime}')"
          [[ -z $failure ]]
          return
          ;;
      esac
      if [[ $hook_result[1] == handled ]]; then
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
        sf_backend_context_window "$tools" "$max_capture" \
          < <(printf '%s\n' "${SF_SESSION_RECORDS[@]}")
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
        sf_session_update "$session" "$runtime" || { failure=$SF_SESSION_ERROR; break; }
        sf_run_emit "$(jq -cn --argjson runtime "$runtime" \
          '{type:"_session_update",runtime:$runtime}')" || {
          failure='cannot emit session update'
          break
        }
      fi
      sf_backend_request "$tools" sf_run_emit \
        < <(printf '%s\n' "${SF_SESSION_RECORDS[@]}")
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
        call_projected=$(jq -jr '.id,"\u0000",.name,"\u0000",(.input|tojson),"\u0000"' \
          <<<"$call") || { failure='cannot inspect provider tool call'; break; }
        call_fields=( "${(@0)${call_projected%$'\0'}}" )
        id=$call_fields[1]
        name=$call_fields[2]
        input=$call_fields[3]
        sf_run_tool_plan "$runtime" "$id" "$name" "$input" || { failure=$SF_RUN_TOOL_ERROR; break; }
        tool_plan=( "${reply[@]}" )
        tool_request=$tool_plan[1]
        activity=$tool_plan[2]
        decision=$tool_plan[3]
        permission_reason=$tool_plan[4]
        permission_preview=$tool_plan[5]
        executable=$tool_plan[6]
        tool_environment=$tool_plan[7]
        settings=$tool_plan[8]
        max_capture=$tool_plan[9]
        fence=$tool_plan[10]
        env_file=$tool_plan[11]
        execution_input=$tool_plan[12]
        sandbox=$tool_plan[13]
        read_paths=$tool_plan[14]
        write_paths=$tool_plan[15]
        render=$tool_plan[16]
        sf_run_emit "$activity" || { failure='cannot emit tool activity'; break; }
        SF_RUN[active_call]=$id
        SF_RUN[known_outcome]=''
        if (( call_count > tool_limit )); then
          sf_run_tool_refused "tool call denied: per-response limit is $tool_limit" 126
          outcome=$REPLY
        else
          sf_run_hooks "$session" pre_tool_use "$tool_request" \
            "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
          hook_result=( "${reply[@]}" )
          if [[ $hook_result[1] == deny ]]; then
            sf_run_tool_refused 'tool call denied by pre_tool_use hook' 126
            outcome=$REPLY
          elif [[ -z $executable ]]; then
            sf_run_tool_refused "tool is not allowed: $name" 127
            outcome=$REPLY
          else
            if [[ $decision == failure ]]; then
              failure=$permission_reason
              break
            elif [[ $decision == deny ]]; then
              sf_run_tool_refused "$permission_reason" 126
              outcome=$REPLY
            elif [[ $decision == request ]]; then
              sf_run_hooks "$session" permission_request "$tool_request" \
                "$turn_state" "$name" "$id" || { failure=$SF_RUN_HOOK_ERROR; break; }
              hook_result=( "${reply[@]}" )
              decision=$hook_result[1]
              reason=${hook_result[3]:-sandbox bypass denied}
              if [[ $decision == proceed ]]; then
                sf_run_permission_client "$name" "$input" "$permission_reason" "$permission_preview"
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
              sf_run_tool_execute "$session" "$runtime" "$executable" "$tool_environment" \
                "$settings" "$max_capture" "$fence" "$env_file" "$execution_input" \
                "$sandbox" "$read_paths" "$write_paths" "$tool_temp"
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
        sf_run_tool_complete "$tool_request" "$id" "$name" "$input" "$executable" \
          "$render" "$outcome" || { failure=$SF_RUN_TOOL_ERROR; break; }
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
