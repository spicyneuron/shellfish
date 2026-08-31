emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

typeset -g SF_HOOK_ERROR=''
# Ordered hook, status, stdout, stderr, and control quintets.
typeset -ga SF_HOOK_RESULTS=()
typeset -g SF_HOOK_CONTEXT_COUNT=0
typeset -ga SF_HOOK_CONTEXT_RECORDS=()
# Preserve an inherited hook state directory across turn setup.
typeset -g SHELLFISH_STATE_DIR=${SHELLFISH_STATE_DIR-}
typeset -g SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
typeset -g SF_HOOKS_EVENT=''
typeset -g SF_HOOK_ACTIVE_PID=''
# Cancellation takes its pending exit at the first nested return, so cleanup
# written after that point never runs. These name the paths this process made,
# never an inherited one, and zshexit removes whatever a cancelled turn left.
typeset -g SF_HOOK_STATE_TEMP=''
typeset -g SF_HOOK_INPUT_TEMP=''

zshexit() {
  [[ -z $SF_HOOK_STATE_TEMP ]] || rm -rf -- "$SF_HOOK_STATE_TEMP" 2>/dev/null || true
  [[ -z $SF_HOOK_INPUT_TEMP ]] || rm -f -- "$SF_HOOK_INPUT_TEMP" 2>/dev/null || true
}

sf_hooks_reset() {
  SF_HOOK_ERROR=''
  SF_HOOK_RESULTS=()
  SF_HOOK_CONTEXT_COUNT=0
  SF_HOOK_CONTEXT_RECORDS=()
  REPLY=''
  reply=()
}

sf_hooks_fail() {
  local error=$1
  sf_hooks_reset
  SF_HOOK_ERROR=$error
  REPLY=''
  reply=()
  return 1
}

sf_hooks_require_lock() {
  local event=$1 session=$2
  [[ -n $SF_SESSION_LOCK && $SF_SESSION_PATH == "$session" ]] ||
    sf_hooks_fail "$event requires the active session lock"
}

sf_hooks_read_capture() {
  local capture=$1 value=''
  local LC_ALL=C
  integer bytes=$2 fd
  if (( bytes )); then
    exec {fd}<"$capture" || return
    sysread -i $fd -s $bytes value
    integer read_status=$?
    exec {fd}<&-
    (( read_status == 0 && ${#value} == bytes )) || return 1
  fi
  REPLY=$value
}

sf_hooks_capture_one() {
  local hook=$1 input=$2 directory=$3
  setopt local_options no_monitor
  integer argument_count=$4
  shift 4
  local -a arguments=( "${(@)argv[1,argument_count]}" )
  local -a environment=( env -u SHELLFISH_API_KEY -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY )
  local context="$directory/current-context"
  local display="$directory/current-display"
  local control="$directory/current-control"
  local PLUGIN_ROOT=${hook:h} PLUGIN_DATA data_root event=$SF_HOOKS_EVENT api_key_env
  integer hook_status

  [[ -n $event ]] || {
    sf_hooks_fail 'hook event is not available'
    return
  }
  if [[ -n ${XDG_STATE_HOME-} ]]; then
    data_root="$XDG_STATE_HOME/shellfish/hooks"
  elif [[ -n ${HOME-} ]]; then
    data_root="$HOME/.local/state/shellfish/hooks"
  else
    sf_hooks_fail 'HOME or XDG_STATE_HOME is required for persistent hook data'
    return
  fi
  PLUGIN_DATA="$data_root/$event/${hook:t}"
  mkdir -p "$PLUGIN_DATA" && chmod 700 "$PLUGIN_DATA" || {
    sf_hooks_fail "cannot prepare persistent hook data: $hook"
    return
  }
  export PLUGIN_ROOT PLUGIN_DATA
  api_key_env=$(jq -r '.backend.api_key_env' <<<"$SF_SESSION[runtime]") || {
    sf_hooks_fail 'cannot inspect hook credential environment'
    return
  }
  [[ -z $api_key_env ]] || environment+=( -u "$api_key_env" )

  rm -f -- "$context" "$display" "$control"

  "${environment[@]}" "$hook" "${arguments[@]}" \
    <"$input" >"$context" 2>"$display" 3>"$control" &
  integer hook_pid=$!
  SF_HOOK_ACTIVE_PID=$hook_pid
  wait "$hook_pid"
  hook_status=$?
  SF_HOOK_ACTIVE_PID=''
  reply=( "$hook_status" "$context" "$display" "$control" )
}

sf_hooks_dispatch() {
  local input=$1
  integer max_capture=$2 allow_control=$3 argument_count=$4
  shift 4
  (( argument_count >= 0 && argument_count <= $# )) || {
    sf_hooks_fail 'invalid hook argument count'
    return
  }
  local -a arguments=( "${(@)argv[1,argument_count]}" )
  shift argument_count
  local -a hooks=( "$@" ) result results
  local directory hook hook_context hook_display hook_control
  local origin='' control=''
  integer hook_status context_size display_size control_size
  integer perform=1 halted=0
  setopt local_options no_err_exit no_bg_nice

  sf_hooks_reset

  directory=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-hooks.XXXXXX") || {
    sf_hooks_fail 'cannot prepare hook captures'
    return
  }
  {
    [[ -f $input ]] || {
      sf_hooks_fail 'cannot prepare hook input'
      return
    }

    for hook in $hooks; do
      sf_hooks_capture_one "$hook" "$input" "$directory" \
        "$argument_count" "${arguments[@]}" || return
      result=( "${reply[@]}" )
      hook_status=$result[1]

      context_size=$(wc -c <"$result[2]") || {
        sf_hooks_fail "cannot inspect hook context: $hook"
        return
      }
      display_size=$(wc -c <"$result[3]") || {
        sf_hooks_fail "cannot inspect hook display: $hook"
        return
      }
      control_size=$(wc -c <"$result[4]") || {
        sf_hooks_fail "cannot inspect hook control: $hook"
        return
      }
      (( context_size + display_size + control_size <= max_capture )) || {
        sf_hooks_fail "hook output exceeds capture limit: $hook"
        return
      }

      case $hook_status in
        0|10|11) ;;
        *)
          hook_display=''
          sf_hooks_read_capture "$result[3]" "$display_size" || {
            sf_hooks_fail "cannot read hook display: $hook"
            return
          }
          hook_display=$REPLY
          sf_hooks_fail "hook failed with status $hook_status: $hook${hook_display:+: $hook_display}"
          return
          ;;
      esac
      if (( control_size )) && (( ! allow_control )); then
        sf_hooks_fail "hook returned unexpected control data: $hook"
        return
      fi
      hook_control=''
      if (( control_size )); then
        hook_control=$(jq -cse '
          if length == 1 and (.[0] | type == "object") then .[0]
          else error("expected one object") end
        ' "$result[4]" 2>/dev/null) || {
          sf_hooks_fail 'hook returned malformed control data'
          return
        }
        control=$hook_control
      fi
      hook_context=''
      sf_hooks_read_capture "$result[2]" "$context_size" || {
        sf_hooks_fail "cannot read hook context: $hook"
        return
      }
      hook_context=$REPLY
      hook_display=''
      sf_hooks_read_capture "$result[3]" "$display_size" || {
        sf_hooks_fail "cannot read hook display: $hook"
        return
      }
      hook_display=$REPLY
      results+=( "$hook" "$hook_status" "$hook_context" "$hook_display" "$hook_control" )
      if (( hook_status == 10 || hook_status == 11 )); then
        [[ -n $origin ]] || origin=$hook
        perform=0
      fi
      if (( hook_status == 11 )); then
        halted=1
        break
      fi
    done

    SF_HOOK_RESULTS=( "${results[@]}" )
  } always {
    rm -rf -- "$directory" 2>/dev/null || true
  }
  REPLY=''
  reply=( "$perform" "$halted" "$origin" "$control" )
}

sf_hooks_state_create() {
  [[ -z $SHELLFISH_STATE_DIR ]] || return 0
  SHELLFISH_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-state.XXXXXX") || {
    sf_hooks_fail 'cannot prepare hook state directory'
    return
  }
  SHELLFISH_STATE_DIR=${SHELLFISH_STATE_DIR:A}
  SF_HOOK_STATE_TEMP=$SHELLFISH_STATE_DIR
  chmod 700 "$SHELLFISH_STATE_DIR" || {
    sf_hooks_state_cleanup
    sf_hooks_fail 'cannot secure hook state directory'
    return
  }
  export SHELLFISH_STATE_DIR
}

sf_hooks_state_cleanup() {
  [[ -z $SHELLFISH_STATE_DIR ]] || rm -rf -- "$SHELLFISH_STATE_DIR" 2>/dev/null || true
  SF_HOOK_STATE_TEMP=''
  unset SHELLFISH_STATE_DIR
}

sf_hooks_invoke() {
  local session=$1 working_directory=$2 input=${3:A}
  integer max_capture=$4 allow_control=$5
  shift 5
  local previous_directory=$PWD
  local event=$2
  local SHELLFISH_SESSION=${session:A}
  local SHELLFISH_CAPTURE_LIMIT=$max_capture
  local SHELLFISH_SESSION_ID=${SHELLFISH_SESSION_ID:-$SF_SESSION[id]}
  local SHELLFISH_MODEL=${SHELLFISH_MODEL:-$SF_SESSION[model]}
  local SHELLFISH_EXECUTABLE=${SF_ENTRY-}
  local PROJECT_DIR=${PROJECT_DIR:-$SF_SESSION[cwd]}
  local SHELLFISH_CONFIG_DIR=${SHELLFISH_CONFIG_DIR-}
  local SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
  local SF_HOOKS_EVENT=$event
  export SHELLFISH_SESSION SHELLFISH_STATE_DIR SHELLFISH_CAPTURE_LIMIT
  export SHELLFISH_SESSION_ID SHELLFISH_MODEL SHELLFISH_EXECUTABLE PROJECT_DIR
  export SHELLFISH_CONFIG_DIR
  if [[ $event == (user_prompt_submit|permission_request|pre_tool_use|post_tool_use|stop) ]]; then
    [[ -n $SHELLFISH_TURN_ID ]] || {
      sf_hooks_fail "$event hook requires a turn ID"
      return
    }
    export SHELLFISH_TURN_ID
  else
    SHELLFISH_TURN_ID=''
    typeset +x SHELLFISH_TURN_ID
  fi

  [[ -n $SHELLFISH_STATE_DIR && -d $SHELLFISH_STATE_DIR ]] || {
    sf_hooks_fail 'hook state directory is not available'
    return
  }
  cd -- "$working_directory" || {
    sf_hooks_fail 'cannot enter session working directory'
    return
  }
  sf_hooks_dispatch "$input" "$max_capture" "$allow_control" "$@"
  integer invocation_status=$?
  cd -- "$previous_directory" || return 1
  return $invocation_status
}

sf_hooks_run_chain() {
  local session=$1 input=$2 event=$3
  integer allow_control=$4 argument_count=$5
  shift 5
  local -a fields hooks

  fields=( "${(@f)$(jq -er --arg event "$event" '
    .harness.max_capture_bytes, (.harness[$event][]?)
  ' <<<"$SF_SESSION[runtime]")}" ) || return 1
  hooks=( "${(@)fields[2,-1]}" )
  local SHELLFISH_SESSION_ID=$SF_SESSION[id]
  local SHELLFISH_MODEL=$SF_SESSION[model]
  local PROJECT_DIR=$SF_SESSION[cwd]
  local config_file SHELLFISH_CONFIG_DIR=''
  config_file=$(jq -r '.backend.env_file // ""' <<<"$SF_SESSION[runtime]") || return 1
  [[ -z $config_file ]] || SHELLFISH_CONFIG_DIR=${config_file:h}
  sf_hooks_invoke "$session" "$SF_SESSION[cwd]" "$input" "$fields[1]" \
    "$allow_control" "$argument_count" "$event" "$@" "${hooks[@]}"
}

sf_hooks_run() {
  local session=$1 event=$2 content=$3 stdout_policy=$4 skip_policy=$5
  integer allow_control=$6 argument_count=$7 operation_status=0 index has_context=0
  shift 7
  local input label=$event
  local -a decision
  [[ $event != pre_tool_use ]] || label=pre-tool

  SF_HOOK_ERROR=''
  if [[ $event == session_start ]]; then
    [[ -z $SF_SESSION_LOCK && $SF_SESSION_PATH == "$session" && ${#SF_SESSION_RECORDS} -gt 0 ]] ||
      sf_hooks_fail 'session_start requires active session preparation' || return
  else
    sf_hooks_require_lock "$event" "$session" || return
  fi
  input=$(mktemp "${TMPDIR:-/tmp}/shellfish-$label.XXXXXX") || {
    sf_hooks_fail "cannot prepare $label hook input"
    return
  }
  SF_HOOK_INPUT_TEMP=$input
  print -rn -- "$content" >"$input" || operation_status=1
  (( operation_status )) || sf_hooks_run_chain "$session" "$input" "$event" \
    "$allow_control" "$argument_count" "$@" || operation_status=1
  decision=( "${reply[@]}" )
  if (( ! operation_status )); then
    for (( index = 3; index <= ${#SF_HOOK_RESULTS}; index += 5 )); do
      [[ -z $SF_HOOK_RESULTS[index] ]] || { has_context=1; break; }
    done
    if [[ $stdout_policy == reject && $has_context == 1 ]]; then
      SF_HOOK_ERROR="$event hook wrote unsupported stdout"
      operation_status=1
    elif (( ! decision[1] )) && [[ $skip_policy == reject ]]; then
      SF_HOOK_ERROR="$event hook returned unsupported skip status"
      operation_status=1
    elif (( ! decision[1] )) && [[ $skip_policy == require_context && $has_context == 0 ]]; then
      SF_HOOK_ERROR="$event hook skipped completion without feedback"
      operation_status=1
    elif [[ $stdout_policy == commit ]] ||
        [[ $stdout_policy == commit_on_skip && $decision[1] == 0 ]]; then
      if [[ $event == session_start ]]; then
        sf_hooks_commit_context "$event" collect || operation_status=1
      else
        sf_hooks_commit_context "$event" || operation_status=1
      fi
    fi
  fi
  rm -f -- "$input" 2>/dev/null || true
  SF_HOOK_INPUT_TEMP=''
  if (( operation_status )); then
    [[ -n $SF_HOOK_ERROR ]] || SF_HOOK_ERROR="cannot prepare $label hook invocation"
    sf_hooks_fail "$SF_HOOK_ERROR"
    return 1
  fi
  REPLY=''
  reply=( "${decision[@]}" )
}

sf_hooks_commit_context() {
  local tag=$1 mode=${2-} context item hook_name control control_json
  integer index
  SF_HOOK_CONTEXT_COUNT=0
  SF_HOOK_CONTEXT_RECORDS=()

  for (( index = 1; index <= ${#SF_HOOK_RESULTS}; index += 5 )); do
    item=$SF_HOOK_RESULTS[index+2]
    [[ -n $item ]] || continue
    hook_name=${SF_HOOK_RESULTS[index]:t}
    control=$SF_HOOK_RESULTS[index+4]
    control_json=${control:-'{}'}
    context=$(print -rn -- "$item" |
      jq -Rsc -L "$SF_ROOT/lib" --arg tag "$tag" --arg hook "$hook_name" \
        --argjson control "$control_json" '
          include "runtime/schema";
          ({type:"context",tag:$tag,hook:$hook,content:.} +
            ($control.context // {})) as $context |
          if ($control.context? // {} | type == "object") and
              ($control.context? // {} | keys - ["prompt", "status"] | length) == 0 and
              ($context | canonical_context)
          then $context
          else error("invalid context control") end
        ') || {
      SF_HOOK_ERROR="hook returned invalid context control: $hook_name"
      return 1
    }
    SF_HOOK_CONTEXT_RECORDS+=( "$context" )
    (( SF_HOOK_CONTEXT_COUNT += 1 ))
  done
  [[ $mode == collect ]] && return 0
  for context in "${SF_HOOK_CONTEXT_RECORDS[@]}"; do
    sf_session_append "$context" || {
      SF_HOOK_ERROR=$SF_SESSION_ERROR
      return 1
    }
  done
}

# Runs once during session preparation.
sf_hooks_session_start() {
  sf_hooks_run "$1" session_start '' commit reject 0 1 || return
  reply=()
}

# Commits prompt context while exec retains the full-turn lock.
sf_hooks_user_prompt_submit_locked() {
  local prompt=$1 session=$2 argument control
  local -a decision handoff
  integer operation_status=0 index control_status

  SF_HOOK_ERROR=''
  unset SHELLFISH_TURN_ID
  sf_hooks_require_lock user_prompt_submit "$session" || return
  SHELLFISH_TURN_ID=$SF_SESSION[turn_id]
  [[ $SHELLFISH_TURN_ID == <1-> ]] || {
    sf_hooks_fail 'cannot derive turn ID'
    unset SHELLFISH_TURN_ID
    return
  }
  export SHELLFISH_TURN_ID
  sf_hooks_run "$session" user_prompt_submit "$prompt" allow allow 1 1 ||
    operation_status=1
  decision=( "${reply[@]}" )
  for (( index = 1; ! operation_status && index <= ${#SF_HOOK_RESULTS}; index += 5 )); do
    control=$SF_HOOK_RESULTS[index+4]
    [[ -n $control ]] || continue
    control_status=$SF_HOOK_RESULTS[index+1]
    if ! jq -L "$SF_ROOT/lib" -e --argjson status "$control_status" '
          include "runtime/schema";
          (keys - ["action", "argv", "context"] | length) == 0 and
          (({type:"context",tag:"user_prompt_submit",hook:"hook",content:""} +
            (.context // {})) | canonical_context) and
          (if has("action") then
             $status == 11 and .action == "handoff" and
             (.argv | type == "array" and length > 0 and
               (.[0] | length > 0) and
               all(.[]; type == "string" and (index("\u0000") | not)))
           else has("argv") | not end)
      ' <<<"$control" >/dev/null; then
      SF_HOOK_ERROR='prompt hook returned invalid control data'
      operation_status=1
    fi
  done
  if (( ! operation_status && decision[2] )); then
    if [[ -z $decision[4] ]] ||
        ! jq -e '.action == "handoff"' <<<"$decision[4]" >/dev/null; then
      SF_HOOK_ERROR='prompt hook halted without a handoff action'
      operation_status=1
    else
      while IFS= read -r -d $'\0' argument; do
        handoff+=( "$argument" )
      done < <(jq -j '.argv[] | ., "\u0000"' <<<"$decision[4]")
    fi
  fi
  (( operation_status )) || sf_hooks_commit_context user_prompt_submit || operation_status=1
  if (( operation_status )); then
    [[ -n $SF_HOOK_ERROR ]] || SF_HOOK_ERROR='cannot prepare prompt hook invocation'
    sf_hooks_fail "$SF_HOOK_ERROR"
    unset SHELLFISH_TURN_ID
    return 1
  fi
  if (( decision[1] )); then
    typeset -g +x SHELLFISH_TURN_ID
    reply=(proceed)
  elif (( decision[2] )); then
    unset SHELLFISH_TURN_ID
    reply=(handoff "${handoff[@]}")
  else
    unset SHELLFISH_TURN_ID
    reply=(handled)
  fi
}

# A skipped completion makes stdout durable feedback; status-0 output is discarded.
sf_hooks_stop() {
  sf_hooks_run "$1" stop "$2" commit_on_skip require_context 0 2 "$3" || return
  if (( reply[1] )); then reply=(finish); else reply=(continue); fi
}

# Hooks decide sandbox bypass on fd 3 or defer to exec's client channel.
sf_hooks_permission_request() {
  local session=$1 tool_name=$2 call_id=$3 tool_input=$4
  local input control_count=0
  local -a result
  integer operation_status=0 index

  SF_HOOK_ERROR=''
  sf_hooks_require_lock permission_request "$session" || return
  input=$(print -rn -- "$tool_input" | jq -c --argjson turn_id "$SHELLFISH_TURN_ID" \
    --arg tool_name "$tool_name" --arg tool_use_id "$call_id" \
    '{turn_id:$turn_id,tool_name:$tool_name,tool_use_id:$tool_use_id,
      tool_input:.}') || operation_status=1
  (( operation_status )) || sf_hooks_run "$session" permission_request "$input" allow allow 1 1 ||
    operation_status=1
  result=( "${reply[@]}" )
  if (( ! operation_status )); then
    for (( index = 1; index <= ${#SF_HOOK_RESULTS}; index += 5 )); do
      [[ -z $SF_HOOK_RESULTS[index+4] ]] || (( control_count += 1 ))
    done
    if (( control_count > 0 && (! result[2] || control_count != 1) )); then
      SF_HOOK_ERROR='permission hook returned invalid decision'
      operation_status=1
    elif (( result[1] )); then
      reply=(defer '')
    elif (( ! result[2] )); then
      reply=(deny '')
    else
      jq -ce '
        if keys == ["action"] and .action == "allow" then true
        elif keys == ["action", "reason"] and .action == "deny" and
            (.reason | type == "string" and length > 0 and
              (index("\u0000") | not))
        then true else error("invalid decision") end
      ' <<<"$result[4]" >/dev/null 2>&1 || {
        SF_HOOK_ERROR='permission hook returned invalid decision'
        operation_status=1
      }
      if (( ! operation_status )); then
        local permission_decision permission_reason=''
        permission_decision=$(jq -r '.action' <<<"$result[4]") ||
          operation_status=1
        if [[ $permission_decision == deny ]]; then
          permission_reason=$(jq -jr '.reason, "\u0001"' \
            <<<"$result[4]") ||
            operation_status=1
          permission_reason=${permission_reason%$'\1'}
        fi
        reply=( "$permission_decision" "$permission_reason" )
      fi
    fi
  fi
  if (( operation_status )); then
    [[ -n $SF_HOOK_ERROR ]] || SF_HOOK_ERROR='cannot prepare permission hook invocation'
    sf_hooks_fail "$SF_HOOK_ERROR"
    return 1
  fi
}

# Gates tool calls under the session lock and uses hook output as denial feedback.
sf_hooks_pre_tool_use() {
  local session=$1 tool_name=$2 call_id=$3 tool_input=$4 input reason
  local -a decision feedback
  integer index

  input=$(print -rn -- "$tool_input" | jq -c --argjson turn_id "$SHELLFISH_TURN_ID" \
    --arg tool_name "$tool_name" --arg tool_use_id "$call_id" \
    '{turn_id:$turn_id,tool_name:$tool_name,tool_use_id:$tool_use_id,
      tool_input:.}') || {
    sf_hooks_fail 'cannot prepare pre-tool hook input'
    return
  }
  sf_hooks_run "$session" pre_tool_use "$input" allow allow 0 1 || return
  decision=( "${reply[@]}" )
  for (( index = 1; index <= ${#SF_HOOK_RESULTS}; index += 5 )); do
    [[ -n $SF_HOOK_RESULTS[index+2] ]] || continue
    if (( SF_HOOK_RESULTS[index+1] == 0 )); then
      sf_hooks_fail 'pre_tool_use hook wrote unsupported stdout'
      return 1
    fi
    feedback+=( "$SF_HOOK_RESULTS[index+2]" )
  done
  if (( decision[1] )); then
    reply=(allow '')
  else
    reason=${(pj:\n:)feedback}
    reply=(deny "${reason:-tool call denied by pre_tool_use hook: ${decision[3]:t}}")
  fi
}

# Observes a committed canonical result; stdout and skip statuses are rejected.
sf_hooks_post_tool_use() {
  local session=$1 result=$2 tool_input=$3 input

  input=$({ print -r -- "$tool_input"; print -r -- "$result"; } |
    jq -cs --argjson turn_id "$SHELLFISH_TURN_ID" '
      .[0] as $tool_input | .[1] as $result |
      {turn_id:$turn_id,tool_name:$result.name,tool_use_id:$result.call_id,
       tool_input:$tool_input,tool_response:($result | {content,exit_code})}
    ') || {
    sf_hooks_fail 'cannot prepare post-tool hook input'
    return
  }
  sf_hooks_run "$session" post_tool_use "$input" reject reject 0 1 || return
  reply=()
}
