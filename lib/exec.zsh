# Bounded non-interactive execution.

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_open] )) || source "$SF_ROOT/lib/session/main.zsh"
(( $+functions[sf_runtime_resolve] )) || source "$SF_ROOT/lib/runtime/main.zsh"
(( $+functions[sf_hooks_session_start] )) || source "$SF_ROOT/lib/hooks.zsh"
(( $+functions[sf_tools_load] )) || source "$SF_ROOT/lib/tools.zsh"
(( $+functions[sf_session_startup_create] )) || source "$SF_ROOT/lib/session/startup.zsh"

typeset -gA SF_EXEC=(
  answer '' backend_error_file '' backend_pid '' error '' jsonl 0
  interrupted 0 partial_events '' permission_count 0 permission_available 0 signal_status 143
)

sf_exec_set_error() {
  SF_EXEC[error]=$1
  return 1
}

sf_exec_emit() {
  (( SF_EXEC[jsonl] )) && print -r -- "$1"
  return 0
}

sf_exec_stop_process() {
  local pid=$1 target=$1 watchdog
  [[ -n $pid ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null && target="-$pid" ||
    kill -TERM "$pid" 2>/dev/null || true
  kill -CONT -- "$target" 2>/dev/null || true
  {
    sleep 0.5
    kill -KILL -- "$target" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  } &
  watchdog=$!
  wait "$pid" 2>/dev/null || true
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

sf_exec_interrupt() {
  SF_EXEC[interrupted]=1
  SF_TOOL_INTERRUPTED=1
  if [[ -n $SF_HOOK_SCRIPT_PID ]]; then
    sf_exec_stop_process "$SF_HOOK_SCRIPT_PID"
    SF_HOOK_SCRIPT_PID=''
  fi
  if [[ -n $SF_EXEC[backend_pid] ]]; then
    sf_exec_stop_process "$SF_EXEC[backend_pid]"
    SF_EXEC[backend_pid]=''
  fi
  if [[ -n $SF_TOOL_ACTIVE_PID ]]; then
    sf_exec_stop_process "$SF_TOOL_ACTIVE_PID"
    SF_TOOL_ACTIVE_PID=''
  fi
}

# Returns 0 to allow, 1 to deny, and 2 when the decision operation failed.
sf_exec_permission() {
  local call_id=$1 name=$2 input=$3 id response decision hook_decision hook_reason
  SF_EXEC[permission_reason]=''
  SF_EXEC[permission_error]=''
  if ! sf_hooks_permission_request "$SF_SESSION_PATH" "$name" "$call_id" "$input"; then
    SF_EXEC[permission_error]=$SF_HOOK_ERROR
    return 2
  fi
  hook_decision=$reply[1]
  hook_reason=$reply[2]
  sf_exec_hook_displays permission_request
  case $hook_decision in
    allow) return 0 ;;
    deny)
      SF_EXEC[permission_reason]=${hook_reason:-sandbox bypass denied}
      return 1
      ;;
  esac
  if (( ! SF_EXEC[permission_available] )); then
    SF_EXEC[permission_reason]='sandbox bypass denied'
    return 1
  fi
  (( SF_EXEC[permission_count] += 1 ))
  id="permission_$SF_EXEC[permission_count]"
  jq -cn --arg id "$id" --arg call_id "$call_id" --arg name "$name" \
    --argjson input "$input" \
    '{type:"_tool_permission_request",id:$id,reason:$input.sandbox_bypass_reason,
      tool:{call_id:$call_id,name:$name,input:$input}}' || {
      SF_EXEC[permission_error]='cannot prepare permission request'
      return 2
    }
  if ! IFS= read -r response; then
    decision=deny
  else
    decision=$(jq -er --arg id "$id" '
      select(type == "object" and keys == ["decision","id","type"] and
        .type == "_tool_permission_response" and .id == $id and
        (.decision | IN("approve","deny"))) | .decision
    ' <<<$response 2>/dev/null) || {
      SF_EXEC[permission_error]='invalid permission response'
      return 2
    }
  fi
  if [[ $decision == approve ]]; then
    return 0
  fi
  SF_EXEC[permission_reason]='sandbox bypass denied'
  return 1
}

sf_exec_error() {
  if (( SF_EXEC[jsonl] )); then
    sf_exec_emit "$(jq -cn --arg message "$1" '{type:"_exec_error",message:$message}')"
  else
    print -r -u2 -- "$1"
  fi
}

sf_exec_hook_displays() {
  local hook=$1
  integer index
  for (( index = 1; index <= ${#SF_HOOK_SCRIPT_RESULTS}; index += 5 )); do
    [[ -n $SF_HOOK_SCRIPT_RESULTS[index+3] ]] || continue
    if (( SF_EXEC[jsonl] )); then
      sf_exec_emit "$(jq -cn --arg hook "$hook" --arg script "$SF_HOOK_SCRIPT_RESULTS[index]" \
        --arg text "$SF_HOOK_SCRIPT_RESULTS[index+3]" \
        '{type:"_hook_display",hook:$hook,script:$script,text:$text}')"
    else
      print -rn -u2 -- "$SF_HOOK_SCRIPT_RESULTS[index+3]"
    fi
  done
}

sf_exec_request() {
  local tools=$1
  printf '%s\n' "${SF_SESSION_RECORDS[@]}" |
    jq -L "$SF_ROOT/lib" -sce --argjson runtime "$SF_SESSION[runtime]" \
    --argjson tools "$tools" '
    include "runtime/schema";
    include "session/request";
    . as $records |
    {
      format_version:1,
      system:([$records[] | select(.type == "system") | .content] | join("\n\n")),
      messages:($records | request_messages),
      tools:$tools,
      options:{request:$runtime.profile.request},
      transport:($runtime.backend | {endpoint,insecure_tls,http_timeout,http_stall})
    } | select(canonical_request)
  '
}

sf_exec_backend() {
  local request=$1 command=$2 error_file adapter_pid adapter_status event decoded kind=''
  local -a events
  # Text and reasoning deltas share one zero-based sequence per provider
  # response, so a client can tell a response start from a mid-response join.
  integer delta_seq=0 ended=0
  SF_EXEC[assistant]=''
  SF_EXEC[backend_error]=''
  SF_EXEC[partial_events]=''
  sf_scratch_file backends exec-error || {
    SF_EXEC[backend_error]='cannot prepare provider error capture'
    return 1
  }
  error_file=$REPLY
  SF_EXEC[backend_error_file]=$error_file
  coproc SHELLFISH_API_KEY="$SF_API_KEY" \
    SHELLFISH_API_KEY_SOURCE="$SF_API_KEY_SOURCE" \
    "$command" <<<"$request" 2>"$error_file"
  adapter_pid=$!
  SF_EXEC[backend_pid]=$adapter_pid
  sf_exec_emit '{"type":"_backend_request_start"}'
  while IFS= read -r event <&p; do
    decoded=$(jq -L "$SF_ROOT/lib" -cr --argjson seq "$delta_seq" '
      include "runtime/schema";
      if canonical_backend_event | not then "invalid"
      elif .type == "_assistant_delta" or .type == "_assistant_reasoning_delta" then
        "delta", (.seq = $seq)
      elif .type == "_assistant_reasoning_opaque" then "opaque"
      elif .type == "_turn_usage" then "usage"
      elif .type == "_assistant_response_end" then "end"
      else "internal" end
    ' <<<"$event" 2>/dev/null) || decoded=invalid
    kind=${decoded%%$'\n'*}
    (( ! ended )) || kind=invalid
    case $kind in
      delta|opaque)
        events+=( "$event" )
        [[ -z $SF_EXEC[partial_events] ]] || SF_EXEC[partial_events]+=$'\n'
        SF_EXEC[partial_events]+=$event
        if [[ $kind == delta ]]; then
          sf_exec_emit "${decoded#*$'\n'}"
          (( ++delta_seq ))
        fi
        ;;
      usage)
        events+=( "$event" )
        sf_exec_emit "$event"
        ;;
      internal) events+=( "$event" ) ;;
      end)
        events+=( "$event" )
        ended=1
        ;;
      *) kind=invalid; break ;;
    esac
  done
  if [[ $kind == invalid ]]; then
    sf_exec_stop_process "$adapter_pid"
    adapter_status=1
  elif wait "$adapter_pid"; then adapter_status=0
  else adapter_status=$?
  fi
  SF_EXEC[backend_pid]=''
  if [[ $kind != invalid && $adapter_status == 0 ]] && (( ended )); then
    SF_EXEC[assistant]=$(printf '%s\n' "${events[@]}" | jq -L "$SF_ROOT/lib" -cse '
      include "runtime/schema";
      assemble_backend_response
    ' 2>/dev/null) || kind=invalid
    [[ -z $SF_EXEC[assistant] ]] || SF_EXEC[partial_events]=''
  fi
  if [[ $kind == invalid || $adapter_status != 0 || -z $SF_EXEC[assistant] ]]; then
    if [[ -s $error_file ]]; then
      SF_EXEC[backend_error]=$(LC_ALL=C tr -s '[:cntrl:]' ' ' <"$error_file" | cut -c 1-1000)
    elif [[ $kind == invalid ]]; then
      SF_EXEC[backend_error]='backend emitted an invalid event stream'
    else
      SF_EXEC[backend_error]='backend exited before completing a response'
    fi
    rm -f -- "$error_file"
    SF_EXEC[backend_error_file]=''
    return 1
  fi
  rm -f -- "$error_file"
  SF_EXEC[backend_error_file]=''
}

sf_exec_partial_assistant() {
  REPLY=''
  [[ -n $SF_EXEC[partial_events] ]] || return 0
  REPLY=$({
    print -r -- "$SF_EXEC[partial_events]"
    print -r -- '{"type":"_assistant_response_end","stop":"length"}'
  } | jq -L "$SF_ROOT/lib" -cse '
    include "runtime/schema";
    assemble_backend_response |
    select(any(.content[]; (.type == "text" or .type == "reasoning") and .text != ""))
  ' 2>/dev/null) || REPLY=''
}

# Zsh defers a trap's pending exit until this cleanup call returns.
sf_exec_turn_cleanup() {
  integer interrupted=$1
  local failure=$2 after=$3 recovered='' partial='' close_failure=''

  sf_tools_cleanup
  sf_hooks_turn_state_cleanup
  [[ -z $SF_EXEC[backend_error_file] ]] ||
    rm -f -- "$SF_EXEC[backend_error_file]" 2>/dev/null || true
  if { (( interrupted )) || [[ -n $failure ]] } && [[ -n $SF_SESSION_LOCK ]]; then
    sf_exec_partial_assistant
    partial=$REPLY
    if [[ -n $partial ]]; then
      if sf_session_append "$partial"; then
        recovered=$partial
      else
        failure=$SF_SESSION_ERROR
      fi
    fi
    if sf_session_recover_turn; then
      if [[ -n $REPLY ]]; then
        [[ -z $recovered ]] || recovered+=$'\n'
        recovered+=$REPLY
      fi
    else
      failure=$SF_SESSION_ERROR
    fi
  fi
  SF_EXEC[partial_events]=''
  [[ -z $recovered ]] || sf_exec_emit "$recovered"
  if [[ -n $SF_SESSION_LOCK ]]; then
    if (( interrupted )); then
      sf_session_close || sf_exec_error "$SF_SESSION_ERROR"
    else
      sf_session_close || close_failure=$SF_SESSION_ERROR
    fi
  fi
  if (( ! interrupted )); then
    [[ -z $failure ]] || sf_exec_error "$failure"
    [[ -z $close_failure ]] || sf_exec_error "$close_failure"
    [[ -n $failure || -n $close_failure || -z $after ]] || sf_exec_emit "$after"
    [[ -z $failure && -z $close_failure ]]
  fi
}

sf_exec_turn() {
  local user_record=$1 session_path=$2 permission_available=${3:-0} prompt
  local request assistant stop_input call result backend_command opened_records
  local tool_name call_id tool_input decision denial_reason hook_action hook_reason
  local runtime_projection user_projection response_projection response_meta
  local tools tool_schema max_capture fence config_file config_dir
  local sandbox_read_paths sandbox_write_paths
  local context_output context_line context_window context_window_command update_event adapter_pid
  local SHELLFISH_TURN_STATE='' SHELLFISH_SESSION_STATE='' SF_API_KEY='' SF_API_KEY_SOURCE=''
  local -a runtime_fields user_fields response_fields tool_calls handoff
  integer request_count=0 stop_count=0 call_count tool_index
  integer harness_sandbox tool_limit request_limit context_window_set
  integer permission_status
  integer permission_hook_available=0 permission_decision_available=0
  local failure='' after='' patch=''

  SF_EXEC[permission_count]=0
  SF_EXEC[permission_available]=$permission_available
  trap 'sf_exec_interrupt; exit $SF_EXEC[signal_status]' TERM
  if ! sf_session_open "$session_path"; then
    sf_exec_error "$SF_SESSION_ERROR"
    return 1
  fi
  opened_records=$REPLY

  {
    [[ -z $opened_records ]] || sf_exec_emit "$opened_records"
    runtime_projection=$(jq -jrn --argjson runtime "$SF_SESSION[runtime]" '
      def field: ., "\u0000";
      ($runtime.backend.command | field),
      (if $runtime.harness.sandbox then "1" else "0" end | field),
      ($runtime.harness.max_tool_calls_per_request | tostring | field),
      ($runtime.harness.max_requests_per_turn | tostring | field),
      ($runtime.harness.max_capture_bytes | tostring | field),
      ($runtime.harness.fence | field),
      ($runtime.harness.sandbox_read_paths | tojson | field),
      ($runtime.harness.sandbox_write_paths | tojson | field),
      (if ($runtime.harness.permission_request // [] | length) > 0 then "1" else "0" end | field),
      ($runtime.harness.tools | tojson | field),
      ($runtime.backend.env_file | field),
      ($runtime.backend.context_window_command // "" | field),
      (if $runtime.profile | has("context_window") then "1" else "0" end | field),
      ("ok" | field)
    ' 2>/dev/null) || {
      failure='cannot inspect frozen runtime'
      return 1
    }
    runtime_fields=( "${(@0)${runtime_projection%$'\0'}}" )
    (( ${#runtime_fields} == 14 )) && [[ $runtime_fields[14] == ok ]] || {
      failure='cannot inspect frozen runtime'
      return 1
    }
    backend_command=$runtime_fields[1]
    harness_sandbox=$runtime_fields[2]
    tool_limit=$runtime_fields[3]
    request_limit=$runtime_fields[4]
    max_capture=$runtime_fields[5]
    fence=$runtime_fields[6]
    sandbox_read_paths=$runtime_fields[7]
    sandbox_write_paths=$runtime_fields[8]
    permission_hook_available=$runtime_fields[9]
    tools=$runtime_fields[10]
    config_file=$runtime_fields[11]
    context_window_command=$runtime_fields[12]
    context_window_set=$runtime_fields[13]
    config_dir=''
    [[ -z $config_file ]] || config_dir=${config_file:h}
    [[ -d $SF_SESSION[cwd] && -x $SF_SESSION[cwd] ]] || {
      failure="session working directory is unavailable: $SF_SESSION[cwd]"
      return 1
    }
    user_projection=$(jq -L "$SF_ROOT/lib" -jnre --argjson record "$user_record" '
      include "runtime/schema";
      def field: ., "\u0000";
      $record | select(canonical_user_message) |
      (tojson | field), (.content[0].text | field), ("ok" | field)
    ' 2>/dev/null) || {
      failure='exec requires a canonical user message'
      return 1
    }
    user_fields=( "${(@0)${user_projection%$'\0'}}" )
    (( ${#user_fields} == 3 )) && [[ $user_fields[3] == ok ]] || {
      failure='cannot inspect user message'
      return 1
    }
    user_record=$user_fields[1]
    prompt=$user_fields[2]
    if ! sf_hooks_turn_state_create; then
      failure=$SF_HOOK_ERROR
      return 1
    fi
    if ! sf_hooks_user_prompt_submit_locked "$prompt" "$session_path"; then
      failure=$SF_HOOK_ERROR
      return 1
    fi
    hook_action=$reply[1]
    handoff=( "${(@)reply[2,-1]}" )
    [[ $hook_action != session_update ]] || patch=$reply[2]
    (( ! SF_HOOK_CONTEXT_COUNT )) ||
      sf_exec_emit "${(pj:\n:)SF_SESSION_RECORDS[-SF_HOOK_CONTEXT_COUNT,-1]}"
    sf_exec_hook_displays user_prompt_submit
    case $hook_action in
      handoff)
        after=$(jq -cn --args '$ARGS.positional |
          {type:"_handoff",argv:.}' -- "${handoff[@]}") || {
          failure='cannot prepare handoff'
          return 1
        }
        return
        ;;
      session_update)
        if ! sf_session_update "$patch"; then
          failure=$SF_SESSION_ERROR
          return 1
        fi
        after=$(jq -cn --argjson runtime "$SF_SESSION[runtime]" \
          '{type:"_session_update",runtime:$runtime}') || {
          failure='cannot prepare session update'
          return 1
        }
        return
        ;;
      handled)
        return
        ;;
    esac
    (( permission_available || permission_hook_available )) && permission_decision_available=1
    if ! sf_tools_load "$tools" "$permission_decision_available" \
        "$SF_SESSION[cwd]" "$max_capture" "$harness_sandbox" "$fence"; then
      failure=$SF_TOOL_ERROR
      return 1
    fi
    tool_schema=$REPLY
    if ! sf_session_append "$user_record"; then
      failure=$SF_SESSION_ERROR
      return 1
    fi
    sf_exec_emit "$user_record"

    while true; do
      (( request_count += 1 ))
      if (( request_count > request_limit )); then
        failure="provider request limit reached: $request_limit"
        return 1
      fi
      request=$(sf_exec_request "$tool_schema") || {
        failure='cannot prepare provider request'
        return 1
      }
      if (( request_count == 1 )) && ! sf_runtime_resolve_api_key "$SF_SESSION[runtime]"; then
        failure=$SF_RUNTIME_ERROR
        return 1
      fi
      if (( request_count == 1 )); then
        SF_API_KEY=$REPLY
        SF_API_KEY_SOURCE=$reply[1]
      fi
      if (( request_count == 1 && ! context_window_set )) &&
          [[ -n $context_window_command ]]; then
        context_output=''
        coproc SHELLFISH_API_KEY="$SF_API_KEY" \
          SHELLFISH_API_KEY_SOURCE="$SF_API_KEY_SOURCE" \
          "$context_window_command" <<<"$request" 2>/dev/null
        adapter_pid=$!
        SF_EXEC[backend_pid]=$adapter_pid
        while IFS= read -r context_line <&p; do
          [[ -z $context_output ]] || context_output+=$'\n'
          context_output+=$context_line
        done
        if ! wait "$adapter_pid"; then
          context_output=''
        fi
        SF_EXEC[backend_pid]=''
        context_window=$(jq -L "$SF_ROOT/lib" -ser '
          include "runtime/schema";
          select(length == 1 and (.[0] | type == "object" and
            keys == ["context_window"] and (.context_window | positive_integer))) |
          .[0].context_window
        ' <<<"$context_output" 2>/dev/null) || context_window=''
        if [[ -n $context_window ]]; then
          patch=$(jq -cn --argjson context_window "$context_window" \
            '{profile:{context_window:$context_window}}') || {
            failure='cannot prepare context window update'
            return 1
          }
          if ! sf_session_update "$patch"; then
            failure=$SF_SESSION_ERROR
            return 1
          fi
        else
          if ! sf_session_update '{"profile":{"context_window":null}}'; then
            failure=$SF_SESSION_ERROR
            return 1
          fi
        fi
        update_event=$(jq -cn --argjson runtime "$SF_SESSION[runtime]" \
          '{type:"_session_update",runtime:$runtime}') || {
          failure='cannot prepare context window update'
          return 1
        }
        sf_exec_emit "$update_event"
      fi
      if ! sf_exec_backend "$request" "$backend_command"; then
        failure=$SF_EXEC[backend_error]
        return 1
      fi
      assistant=$SF_EXEC[assistant]
      if ! sf_session_append "$assistant"; then
        failure=$SF_SESSION_ERROR
        return 1
      fi
      sf_exec_emit "$assistant"
      response_projection=$(jq -jr '
        .stop,
        (.content[] | select(.type == "tool_call") |
          ("\n", tojson, "\n", .id, "\n", .name, "\n", (.input | tojson))),
        "\u001e",
        ([.content[] | select(.type == "text") | .text] | join("")),
        "\u001e"
      ' <<<"$assistant") || {
        failure='cannot inspect provider response'
        return 1
      }
      [[ $response_projection == *$'\x1e'* ]] || {
        failure='cannot inspect provider response'
        return 1
      }
      response_meta=${response_projection%%$'\x1e'*}
      stop_input=${response_projection#*$'\x1e'}
      [[ $stop_input == *$'\x1e' ]] || {
        failure='cannot inspect provider response'
        return 1
      }
      stop_input=${stop_input%$'\x1e'}
      response_fields=( "${(@f)response_meta}" )
      (( ${#response_fields} >= 1 && (${#response_fields} - 1) % 4 == 0 )) || {
        failure='cannot inspect provider response'
        return 1
      }
      if [[ $response_fields[1] != tool_calls ]]; then
        (( stop_count += 1 ))
        if ! sf_hooks_stop "$session_path" "$stop_input" "$stop_count"; then
          failure=$SF_HOOK_ERROR
          return 1
        fi
        hook_action=$reply[1]
        sf_exec_hook_displays stop
        if [[ $hook_action == finish ]]; then
          SF_EXEC[answer]=$stop_input
          return
        fi
        sf_exec_emit "${(pj:\n:)SF_SESSION_RECORDS[-SF_HOOK_CONTEXT_COUNT,-1]}"
        continue
      fi
      call_count=0
      tool_calls=( "${(@)response_fields[2,-1]}" )
      for (( tool_index = 1; tool_index <= ${#tool_calls}; tool_index += 4 )); do
        (( call_count += 1 ))
        call=$tool_calls[tool_index]
        call_id=$tool_calls[tool_index+1]
        tool_name=$tool_calls[tool_index+2]
        tool_input=$tool_calls[tool_index+3]
        if (( call_count > tool_limit )); then
          if ! sf_tool_result "$call_id" "$tool_name" \
              "tool call denied: per-response limit is $tool_limit" 126; then
            failure=${SF_TOOL_ERROR:-cannot prepare denied tool result}
            return 1
          fi
          result=$REPLY
        else
          if ! sf_hooks_pre_tool_use "$session_path" "$tool_name" "$call_id" "$tool_input"; then
            failure=$SF_HOOK_ERROR
            return 1
          fi
          hook_action=$reply[1]
          hook_reason=$reply[2]
          sf_exec_hook_displays pre_tool_use
          if [[ $hook_action == deny ]]; then
            if ! sf_tool_result "$call_id" "$tool_name" \
                "$hook_reason" \
                126; then
              failure=${SF_TOOL_ERROR:-cannot prepare denied tool result}
              return 1
            fi
            result=$REPLY
          else
            decision=''
            denial_reason=''
            sf_tool_needs_permission "$tool_name" "$tool_input" "$tools" "$harness_sandbox"
            permission_status=$?
            if (( permission_status == 0 )); then
              permission_status=0
              sf_exec_permission "$call_id" "$tool_name" "$tool_input" ||
                permission_status=$?
              case $permission_status in
                0) decision=approved ;;
                1) denial_reason=$SF_EXEC[permission_reason] ;;
                *)
                  failure=$SF_EXEC[permission_error]
                  return 1
                  ;;
              esac
            elif (( permission_status == 2 )); then
              failure=$SF_TOOL_ERROR
              return 1
            fi
            if ! sf_tool_execute "$call" "$harness_sandbox" "$decision" "$denial_reason" \
                "$tools" "$SF_SESSION[cwd]" "$max_capture" "$fence" \
                "$sandbox_read_paths" "$sandbox_write_paths" "$config_dir" \
                "$SF_SESSION[id]"; then
              failure=${SF_TOOL_ERROR:-shell tool execution failed}
              return 1
            fi
            result=$REPLY
          fi
        fi
        if ! sf_session_append "$result"; then
          failure=$SF_SESSION_ERROR
          return 1
        fi
        sf_exec_emit "$result"
        if ! sf_hooks_post_tool_use "$session_path" "$result" "$tool_input"; then
          failure=$SF_HOOK_ERROR
          return 1
        fi
        sf_exec_hook_displays post_tool_use
      done
    done
  } always {
    trap - TERM
    sf_exec_turn_cleanup "$SF_EXEC[interrupted]" "$failure" "$after"
  }
}

sf_exec_run() {
  local message=$1 requested_session=${2-} requested_config=${3-} requested_profile=${4-}
  local requested_model=${5-} requested_request=${6:-\{\}} requested_backend=${7-}
  integer runtime_override=${8:-0} continue_requested=${9:-0} jsonl=${10:-0} new=${11:-0}
  local new_source=${12-}
  integer rc=0 create=0
  local selected runtime record
  local -a startup_records

  SF_EXEC[error]=''
  SF_EXEC[answer]=''
  SF_EXEC[partial_events]=''
  SF_EXEC[interrupted]=0
  SF_TOOL_INTERRUPTED=0
  SF_EXEC[signal_status]=143
  SF_EXEC[jsonl]=$jsonl
  typeset -gx SHELLFISH_MODE=exec
  if (( continue_requested )); then
    sf_session_find 1
    rc=$?
    if (( rc )); then
      sf_exec_set_error "$SF_SESSION_ERROR"
    else
      requested_session=$SF_SESSION_MATCHES[1]
    fi
  fi
  if (( ! rc )); then
    sf_session_select_path "$requested_session" || {
      rc=$?
      sf_exec_set_error "$SF_SESSION_ERROR"
    }
  fi
  if (( ! rc )); then
    selected=$REPLY
    if [[ -s $selected ]]; then
      if (( runtime_override )); then
        sf_exec_set_error 'runtime overrides cannot be used with an existing session'
        rc=2
      fi
    elif [[ -e $selected && ( ! -f $selected || -L $selected ) ]]; then
      sf_exec_set_error "invalid session path: $selected"
      rc=$?
    else
      create=1
      if [[ -n $new_source ]]; then
        sf_session_read_settings "$new_source" || {
          rc=$?
          sf_exec_set_error "$SF_SESSION_ERROR"
        }
        (( rc )) || runtime=$REPLY
      else
        sf_runtime_resolve '' "$requested_config" "$requested_profile" \
            "$requested_model" "$requested_request" "$requested_backend" \
            "$runtime_override" || {
          rc=$?
          sf_exec_set_error "$SF_RUNTIME_ERROR"
        }
        (( rc )) || runtime=$REPLY
      fi
    fi
  fi
  trap 'SF_EXEC[signal_status]=130; kill -TERM $$' INT
  trap 'SF_EXEC[signal_status]=129; kill -TERM $$' HUP
  trap 'sf_exec_interrupt; exit $SF_EXEC[signal_status]' TERM
  if (( ! rc && create )); then
    if sf_session_startup_create "$selected" "$runtime"; then
      startup_records=( "${SF_SESSION_RECORDS[@]}" )
    else
      sf_exec_set_error "$SF_SESSION_STARTUP_ERROR"
      rc=1
    fi
  fi
  if (( ! rc && new )); then
    print -r -- "$selected"
    return
  fi
  for record in "${startup_records[@]}"; do
    sf_exec_emit "$record"
  done
  (( rc )) || sf_exec_hook_displays session_start
  if (( rc )); then
    if (( jsonl )); then
      sf_exec_error "$SF_EXEC[error]"
      SF_EXEC[error]=''
    fi
    trap - INT HUP TERM
    return $rc
  fi
  SHELLFISH_TURN_STATE=''
  SHELLFISH_SESSION_STATE=''
  sf_exec_turn "$message" "$selected" "$jsonl"
  rc=$?
  trap - INT HUP TERM
  if (( ! jsonl )) && [[ -n $SF_EXEC[answer] ]]; then
    print -r -- "$SF_EXEC[answer]"
  fi
  return $rc
}
