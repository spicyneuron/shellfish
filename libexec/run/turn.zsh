emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/session.zsh"
source "$SF_ROOT/lib/profile.zsh"
source "$SF_ROOT/lib/backend.zsh"
source "$SF_ROOT/lib/scratch.zsh"
source "$SF_ROOT/libexec/run/hooks.zsh"
source "$SF_ROOT/libexec/run/tools.zsh"

typeset -gA SF_RUN=(
  active_call '' answer '' assistant '' jsonl 0 known_outcome '' permission_count 0 signal_status 0
  hook_id 1 hooks '' hooks_known 0 write_failed 0
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
  local -A completed
  sf_jq_fields -Rs '
    include "lib/fields";
    include "lib/session";
    [split("\n")[1:][] | select(length > 0) | fromjson] |
    session_run |
    (.calls[] | {id,name,input} | tojson | field),
    ("ok" | field)
  ' "$session" || {
    REPLY='cannot inspect pending tool calls'
    return 1
  }
  calls=( "${reply[@]}" )
  for call in "${calls[@]}"; do
    sf_run_tool_plan "$call" || {
      REPLY=${SF_RUN_TOOL_ERROR:-cannot inspect pending tool call}
      return 1
    }
    if [[ $SF_TOOL_PLAN[id] == $active && -n $known ]]; then
      outcome=$known
    elif [[ $SF_TOOL_PLAN[id] == $active ]]; then
      sf_run_tool_refused 'tool call interrupted' 126
      outcome=$REPLY
    else
      sf_run_tool_refused "$reason" 126
      outcome=$REPLY
    fi
    sf_run_tool_complete "$outcome" || {
      REPLY=${SF_RUN_TOOL_ERROR:-cannot finish pending tool call}
      return 1
    }
    completed=( "${reply[@]}" )
    sf_run_append "$session" "$completed[result]" || return 1
  done
}

sf_run_open() {
  local session=$1
  local -A opened
  [[ $session == /* && -f $session && ! -L $session && -r $session ]] || {
    REPLY="invalid session path: $session"
    return 1
  }
  sf_jq_fields -Rs --arg share "$SF_SHARE" --arg home "${HOME:+${HOME:A}}" '
    include "lib/fields";
    include "lib/profile";
    include "lib/session";
    select(endswith("\n")) |
    split("\n") as $lines |
    select($lines[-1] == "" and ($lines[0:-1] | length > 0) and
      all($lines[0:-1][]; length > 0)) |
    ($lines[0:-1] | map(fromjson)) as $records |
    select($records[0] | canonical_session_header) |
    ($records[0] | header_expand($share; $home)) as $header |
    ($records[1:] | session_run) as $run |
    entry("profile"; $header.profile | tojson),
    entry("cwd"; $header.cwd),
    entry("turn_id";
      [$records[1:][] | select(.type == "user")] | length + 1 | tostring),
    entry("pending"; ($run.next != "user") | tostring),
    entry("hook_id";
      [$records[1:][] | select(.type == "hook_result") | .id | tonumber] |
      ((max // 0) + 1) | tostring),
    entry("hooks";
      [hook_names[] as $hook |
        select(($header.profile.hooks[$hook] // []) | length > 0) | $hook] |
      join(" ")),
    ("ok" | field)
  ' "$session" || {
    REPLY="cannot read session: $session"
    return 1
  }
  opened=( "${reply[@]}" )
  SF_RUN[profile]=$opened[profile]
  SF_RUN[cwd]=$opened[cwd]
  SF_RUN[turn_id]=$opened[turn_id]
  SF_RUN[hook_id]=$opened[hook_id]
  SF_RUN[hooks]=$opened[hooks]
  SF_RUN[hooks_known]=1
  sf_profile_tools "$SF_RUN[profile]" || { REPLY=$SF_PROFILE_ERROR; return 1; }
  SF_RUN[tools]=$REPLY
  [[ $opened[pending] == true ]] || return 0
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
  local profile=$1
  sf_jq_fields -rn --argjson profile "$profile" --argjson tools "$SF_RUN[tools]" '
    include "lib/fields";
    [$tools[] |
      .manifest as $manifest |
      (($profile.sandbox and $manifest.sandbox and
        ($manifest.allow_sandbox_bypass // false))) as $bypass |
      {name,description:($manifest.description +
        if $profile.sandbox and $manifest.sandbox
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
    entry("max_requests"; $profile.max_requests_per_turn | tostring),
    entry("max_tool_calls"; $profile.max_tool_calls_per_request | tostring),
    entry("max_capture"; $profile.max_capture_bytes | tostring),
    entry("adapter"; $profile.backend.adapter),
    entry("tools"; $tools | tojson),
    ("ok" | field)
  ' || return 1
}

sf_run_turn() {
  local user_record=$1 session=$2 prompt=$3 profile tools context_command
  local assistant stop_text id name decision post_request
  local reason outcome result state post_error='' failure='' turn_state call
  local call_projection
  local -a calls states
  local -A projected hook_result completed
  integer begun=0 request_count=0 call_count=0 request_limit tool_limit max_capture run_status

  {
    SF_RUN[answer]=''
    SF_RUN[assistant]=''
    SF_RUN[active_call]=''
    SF_RUN[known_outcome]=''
    SF_RUN[permission_count]=0
    SF_RUN[signal_status]=0
    SF_RUN[hooks_known]=0
    SF_RUN[write_failed]=0
    sf_run_open "$session" || { print -r -u2 -- "$REPLY"; return 1; }
    begun=1
    profile=$SF_RUN[profile]
    if sf_run_project "$profile"; then
      projected=( "${reply[@]}" )
      tools=$projected[tools]
      request_limit=$projected[max_requests]
      tool_limit=$projected[max_tool_calls]
      max_capture=$projected[max_capture]
      context_command=$projected[adapter]/context_window
    else
      failure='cannot inspect frozen profile'
    fi
    [[ -z $failure && -d $SF_RUN[cwd] && -x $SF_RUN[cwd] ]] ||
      failure=${failure:-session working directory is unavailable: $SF_RUN[cwd]}
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
          if sf_session_replace_profile "$session" "$hook_result[payload]"; then
            if sf_run_emit "$(jq -cn --argjson profile "$hook_result[payload]" \
                '{type:"_session_update",profile:$profile}')"; then
              return 0
            fi
            failure='cannot emit session update'
          else
            failure=$SF_SESSION_ERROR
          fi
          ;;
      esac
      if [[ -z $failure && $hook_result[action] == block ]]; then
        return 0
      fi
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
      if (( request_count == 1 )) && [[ -f $context_command && -x $context_command ]] &&
          ! jq -e 'has("context_window")' <<<"$profile" >/dev/null; then
        sf_backend_context_window "$context_command" "$tools" "$max_capture" <"$session"
        run_status=$?
        if (( run_status )); then
          if (( run_status == 129 || run_status == 130 || run_status == 143 )); then
            SF_RUN[signal_status]=$run_status
          else
            failure=$SF_BACKEND[error]
          fi
          break
        fi
        profile=$(jq -c --argjson window "$REPLY" \
          '.context_window=$window' <<<"$profile") || {
          failure='cannot update model context window'
          break
        }
        sf_session_replace_profile "$session" "$profile" || { failure=$SF_SESSION_ERROR; break; }
        SF_RUN[profile]=$profile
        sf_run_emit "$(jq -cn --argjson profile "$profile" \
          '{type:"_session_update",profile:$profile}')" || {
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
        if [[ $hook_result[action] != continue ]]; then
          SF_RUN[answer]=$stop_text
          SF_RUN[assistant]=$assistant
          break
        fi
        continue
      fi
      call_count=0
      for call in "${calls[@]}"; do
        (( call_count += 1 ))
        sf_run_tool_plan "$call" || { failure=$SF_RUN_TOOL_ERROR; break; }
        id=$SF_TOOL_PLAN[id]
        name=$SF_TOOL_PLAN[name]
        decision=$SF_TOOL_PLAN[decision]
        [[ -z $SF_TOOL_PLAN[draft] ]] || sf_run_emit "$SF_TOOL_PLAN[event]" ||
          { failure='cannot emit tool draft'; break; }
        SF_RUN[active_call]=$id
        SF_RUN[known_outcome]=''
        if (( call_count > tool_limit )); then
          sf_run_tool_refused "tool call denied: per-response limit is $tool_limit" 126
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
            if [[ -z $outcome ]]; then
              sf_run_tool_execute "$session"
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
        completed=( "${reply[@]}" )
        result=$completed[result]
        post_request=$completed[post_request]
        states=( ${(f)completed[states]} )
        for state in "${states[@]}"; do
          sf_run_append "$session" "$state" || { failure=$REPLY; break 2; }
        done
        SF_RUN[known_outcome]=$outcome
        sf_run_hooks "$session" post_tool_use "$post_request" \
          "$turn_state" "$name" "$id" || post_error=$SF_RUN_HOOK_ERROR
        sf_run_append "$session" "$result" || { failure=$REPLY; break; }
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
    rm -rf -- "$turn_state" 2>/dev/null
    (( ! begun || ! SF_RUN[signal_status] )) || sf_run_cancel "$session"
  }
}
