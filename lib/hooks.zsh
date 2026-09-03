emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

(( $+functions[sf_scratch_category] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_HOOK_ERROR=''
# Ordered script, status, stdout, stderr, and control quintets.
typeset -ga SF_HOOK_SCRIPT_RESULTS=()
typeset -g SF_HOOK_CONTEXT_COUNT=0
typeset -ga SF_HOOK_CONTEXT_RECORDS=()
# Preserve inherited hook state across nested turn setup.
typeset -g SHELLFISH_TURN_STATE=${SHELLFISH_TURN_STATE-}
typeset -g SHELLFISH_SESSION_STATE=${SHELLFISH_SESSION_STATE-}
typeset -g SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
typeset -g SF_HOOK_NAME=''
typeset -g SF_HOOK_SCRIPT_PID=''
integer -g SF_HOOKS_SKIP_TURN=0
# Cancellation takes its pending exit at the first nested return, so cleanup
# written after that point never runs. These name the paths this process made,
# never an inherited one, and zshexit removes whatever a cancelled turn left.
typeset -g SF_HOOK_TURN_STATE_TEMP=''
typeset -g SF_HOOK_INPUT_TEMP=''

zshexit() {
  [[ -z $SF_HOOK_TURN_STATE_TEMP ]] || rm -rf -- "$SF_HOOK_TURN_STATE_TEMP" 2>/dev/null || true
  [[ -z $SF_HOOK_INPUT_TEMP ]] || rm -f -- "$SF_HOOK_INPUT_TEMP" 2>/dev/null || true
}

sf_hooks_reset() {
  SF_HOOK_ERROR=''
  SF_HOOK_SCRIPT_RESULTS=()
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
  local hook=$1 session=$2
  [[ -n $SF_SESSION_LOCK && $SF_SESSION_PATH == "$session" ]] ||
    sf_hooks_fail "$hook requires the active session lock"
}

# A turn can disable its own hooks. Session preparation hooks are unaffected,
# so an existing system record and session-start context still project.
sf_hooks_configured() {
  if (( SF_HOOKS_SKIP_TURN )) &&
      [[ $1 == (user_prompt_submit|permission_request|pre_tool_use|post_tool_use|stop) ]]; then
    return 1
  fi
  (( ! ${+SF_HOOK_COUNTS[$1]} || SF_HOOK_COUNTS[$1] > 0 ))
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
  local script=$1 input=$2 directory=$3
  setopt local_options no_monitor
  integer argument_count=$4
  shift 4
  local -a arguments=( "${(@)argv[1,argument_count]}" )
  local -a environment=( env -u SHELLFISH_API_KEY -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY )
  local context="$directory/current-context"
  local display="$directory/current-display"
  local control="$directory/current-control"
  local HOOK_SCRIPT_ROOT=${script:h} hook=$SF_HOOK_NAME api_key_env
  local -a command
  integer script_status

  [[ -n $hook ]] || {
    sf_hooks_fail 'hook name is not available'
    return
  }
  export HOOK_SCRIPT_ROOT
  api_key_env=$(jq -r '.backend.api_key_env' <<<"$SF_SESSION[runtime]") || {
    sf_hooks_fail 'cannot inspect hook credential environment'
    return
  }
  [[ -z $api_key_env ]] || environment+=( -u "$api_key_env" )

  rm -f -- "$context" "$display" "$control"
  if [[ $hook == system && $script == *.zsh ]]; then
    command=( zsh -f "$script" )
  else
    command=( "$script" )
  fi

  "${environment[@]}" "${command[@]}" "${arguments[@]}" \
    <"$input" >"$context" 2>"$display" 3>"$control" &
  integer script_pid=$!
  SF_HOOK_SCRIPT_PID=$script_pid
  wait "$script_pid"
  script_status=$?
  SF_HOOK_SCRIPT_PID=''
  reply=( "$script_status" "$context" "$display" "$control" )
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
  local -a scripts=( "$@" ) result results
  local directory script script_context script_display script_control hook=$SF_HOOK_NAME
  local origin='' control=''
  integer script_status context_size display_size control_size
  integer perform=1 halted=0
  setopt local_options no_err_exit no_bg_nice

  sf_hooks_reset

  sf_scratch_create hooks capture || {
    sf_hooks_fail 'cannot prepare hook captures'
    return
  }
  directory=$REPLY
  {
    [[ -f $input ]] || {
      sf_hooks_fail 'cannot prepare hook input'
      return
    }

    for script in $scripts; do
      if [[ $hook == system && $script != *.zsh && ! -x $script ]]; then
        [[ -f $script && -r $script ]] || {
          sf_hooks_fail "invalid system hook component: $script"
          return
        }
        context_size=$(wc -c <"$script") || {
          sf_hooks_fail "cannot inspect system hook component: $script"
          return
        }
        (( context_size <= max_capture )) || {
          sf_hooks_fail "hook component output exceeds capture limit: $script"
          return
        }
        sf_hooks_read_capture "$script" "$context_size" || {
          sf_hooks_fail "cannot read system hook component: $script"
          return
        }
        results+=( "$script" 0 "$REPLY" '' '' )
        continue
      fi
      sf_hooks_capture_one "$script" "$input" "$directory" \
        "$argument_count" "${arguments[@]}" || return
      result=( "${reply[@]}" )
      script_status=$result[1]

      context_size=$(wc -c <"$result[2]") || {
        sf_hooks_fail "cannot inspect hook script context: $script"
        return
      }
      display_size=$(wc -c <"$result[3]") || {
        sf_hooks_fail "cannot inspect hook script display: $script"
        return
      }
      control_size=$(wc -c <"$result[4]") || {
        sf_hooks_fail "cannot inspect hook script control: $script"
        return
      }
      (( context_size + display_size + control_size <= max_capture )) || {
        sf_hooks_fail "hook script output exceeds capture limit: $script"
        return
      }

      case $script_status in
        0|10|11) ;;
        *)
          script_display=''
          sf_hooks_read_capture "$result[3]" "$display_size" || {
            sf_hooks_fail "cannot read hook script display: $script"
            return
          }
          script_display=$REPLY
          sf_hooks_fail "hook script failed with status $script_status: $script${script_display:+: $script_display}"
          return
          ;;
      esac
      if (( control_size )) && (( ! allow_control )); then
        sf_hooks_fail "hook script returned unexpected control data: $script"
        return
      fi
      script_control=''
      if (( control_size )); then
        script_control=$(jq -cse '
          if length == 1 and (.[0] | type == "object") then .[0]
          else error("expected one object") end
        ' "$result[4]" 2>/dev/null) || {
          sf_hooks_fail 'hook script returned malformed control data'
          return
        }
        control=$script_control
      fi
      script_context=''
      sf_hooks_read_capture "$result[2]" "$context_size" || {
        sf_hooks_fail "cannot read hook script context: $script"
        return
      }
      script_context=$REPLY
      script_display=''
      sf_hooks_read_capture "$result[3]" "$display_size" || {
        sf_hooks_fail "cannot read hook script display: $script"
        return
      }
      script_display=$REPLY
      results+=( "$script" "$script_status" "$script_context" "$script_display" "$script_control" )
      if (( script_status == 10 || script_status == 11 )); then
        [[ -n $origin ]] || origin=$script
        perform=0
      fi
      if (( script_status == 11 )); then
        halted=1
        break
      fi
    done

    SF_HOOK_SCRIPT_RESULTS=( "${results[@]}" )
  } always {
    rm -rf -- "$directory" 2>/dev/null || true
  }
  REPLY=''
  reply=( "$perform" "$halted" "$origin" "$control" )
}

sf_hooks_session_state_create() {
  [[ -n $SHELLFISH_SESSION_STATE && -d $SHELLFISH_SESSION_STATE ]] && return 0
  local id=${SHELLFISH_SESSION_ID:-$SF_SESSION[id]}
  if [[ -z $id && -n $SF_SESSION_PATH ]]; then
    id=${SF_SESSION_PATH:t}
    id=${id%.jsonl}
  fi
  [[ -n $id && $id != . && $id != .. ]] || {
    sf_hooks_fail 'cannot derive hook session state'
    return
  }
  sf_scratch_directory sessions "$id" || {
    sf_hooks_fail 'cannot prepare hook session state'
    return
  }
  SHELLFISH_SESSION_STATE=$REPLY
  export SHELLFISH_SESSION_STATE
}

sf_hooks_turn_state_create() {
  sf_hooks_session_state_create || return
  [[ -z $SHELLFISH_TURN_STATE ]] || return 0
  sf_scratch_create turns turn || {
    sf_hooks_fail 'cannot prepare hook turn state'
    return
  }
  SHELLFISH_TURN_STATE=$REPLY
  SF_HOOK_TURN_STATE_TEMP=$SHELLFISH_TURN_STATE
  export SHELLFISH_TURN_STATE
}

sf_hooks_turn_state_cleanup() {
  [[ -z $SHELLFISH_TURN_STATE ]] || rm -rf -- "$SHELLFISH_TURN_STATE" 2>/dev/null || true
  SF_HOOK_TURN_STATE_TEMP=''
  unset SHELLFISH_TURN_STATE
}

sf_hooks_invoke() {
  local session=$1 working_directory=$2 input=${3:A}
  integer max_capture=$4 allow_control=$5
  shift 5
  local previous_directory=$PWD
  local hook=$2
  local SHELLFISH_SESSION=${session:A}
  local SHELLFISH_CAPTURE_LIMIT=$max_capture
  local SHELLFISH_SESSION_ID=${SHELLFISH_SESSION_ID:-$SF_SESSION[id]}
  local SHELLFISH_MODEL=${SHELLFISH_MODEL:-$SF_SESSION[model]}
  local SHELLFISH_EXECUTABLE=${SF_ENTRY-}
  local PROJECT_DIR=${PROJECT_DIR:-$SF_SESSION[cwd]}
  local SHELLFISH_CONFIG_DIR=${SHELLFISH_CONFIG_DIR-}
  local SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
  local SF_HOOK_NAME=$hook
  export SHELLFISH_SESSION SHELLFISH_SESSION_STATE SHELLFISH_CAPTURE_LIMIT
  export SHELLFISH_SESSION_ID SHELLFISH_MODEL SHELLFISH_EXECUTABLE PROJECT_DIR
  export SHELLFISH_CONFIG_DIR
  [[ -n $SHELLFISH_SESSION_STATE && -d $SHELLFISH_SESSION_STATE ]] || {
    sf_hooks_fail 'hook session state is not available'
    return
  }
  if [[ $hook == (user_prompt_submit|permission_request|pre_tool_use|post_tool_use|stop) ]]; then
    [[ -n $SHELLFISH_TURN_ID ]] || {
      sf_hooks_fail "$hook hook requires a turn ID"
      return
    }
    [[ -n $SHELLFISH_TURN_STATE && -d $SHELLFISH_TURN_STATE ]] || {
      sf_hooks_fail 'hook turn state is not available'
      return
    }
    export SHELLFISH_TURN_ID SHELLFISH_TURN_STATE
  else
    SHELLFISH_TURN_ID=''
    SHELLFISH_TURN_STATE=''
    typeset +x SHELLFISH_TURN_ID SHELLFISH_TURN_STATE
  fi
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
  local session=$1 input=$2 hook=$3
  integer allow_control=$4 argument_count=$5
  shift 5
  local -a fields scripts

  fields=( "${(@f)$(jq -er --arg hook "$hook" '
    .harness.max_capture_bytes, (.harness[$hook][]?)
  ' <<<"$SF_SESSION[runtime]")}" ) || return 1
  scripts=( "${(@)fields[2,-1]}" )
  local SHELLFISH_SESSION_ID=$SF_SESSION[id]
  local SHELLFISH_MODEL=$SF_SESSION[model]
  local PROJECT_DIR=$SF_SESSION[cwd]
  local config_file SHELLFISH_CONFIG_DIR=''
  config_file=$(jq -r '.backend.env_file // ""' <<<"$SF_SESSION[runtime]") || return 1
  [[ -z $config_file ]] || SHELLFISH_CONFIG_DIR=${config_file:h}
  sf_hooks_invoke "$session" "$SF_SESSION[cwd]" "$input" "$fields[1]" \
    "$allow_control" "$argument_count" "$hook" "$@" "${scripts[@]}"
}

sf_hooks_run() {
  local session=$1 hook=$2 content=$3 stdout_policy=$4 skip_policy=$5
  integer allow_control=$6 argument_count=$7 operation_status=0 index has_context=0
  shift 7
  local input label=$hook
  local -a decision
  [[ $hook != pre_tool_use ]] || label=pre-tool

  SF_HOOK_ERROR=''
  if [[ $hook == (system|session_start) ]]; then
    [[ -z $SF_SESSION_LOCK && $SF_SESSION_PATH == "$session" && ${#SF_SESSION_RECORDS} -gt 0 ]] ||
      sf_hooks_fail "$hook requires active session preparation" || return
  else
    sf_hooks_require_lock "$hook" "$session" || return
  fi
  if ! sf_hooks_configured "$hook"; then
    sf_hooks_reset
    reply=( 1 0 '' '' )
    return 0
  fi
  sf_scratch_file hooks input || {
    sf_hooks_fail "cannot prepare $label hook input"
    return
  }
  input=$REPLY
  SF_HOOK_INPUT_TEMP=$input
  print -rn -- "$content" >"$input" || operation_status=1
  (( operation_status )) || sf_hooks_run_chain "$session" "$input" "$hook" \
    "$allow_control" "$argument_count" "$@" || operation_status=1
  decision=( "${reply[@]}" )
  if (( ! operation_status )); then
    for (( index = 3; index <= ${#SF_HOOK_SCRIPT_RESULTS}; index += 5 )); do
      [[ -z $SF_HOOK_SCRIPT_RESULTS[index] ]] || { has_context=1; break; }
    done
    if [[ $stdout_policy == reject && $has_context == 1 ]]; then
      SF_HOOK_ERROR="$hook hook script wrote unsupported stdout"
      operation_status=1
    elif (( ! decision[1] )) && [[ $skip_policy == reject ]]; then
      SF_HOOK_ERROR="$hook hook script returned unsupported skip status"
      operation_status=1
    elif (( ! decision[1] )) && [[ $skip_policy == require_context && $has_context == 0 ]]; then
      SF_HOOK_ERROR="$hook hook script skipped completion without feedback"
      operation_status=1
    elif [[ $stdout_policy == commit ]] ||
        [[ $stdout_policy == commit_on_skip && $decision[1] == 0 ]]; then
      if [[ $hook == session_start ]]; then
        sf_hooks_commit_context "$hook" collect || operation_status=1
      else
        sf_hooks_commit_context "$hook" || operation_status=1
      fi
    fi
  fi
  rm -f -- "$input" 2>/dev/null || true
  SF_HOOK_INPUT_TEMP=''
  if (( operation_status )); then
    [[ -n $SF_HOOK_ERROR ]] || SF_HOOK_ERROR="cannot prepare $label hook script invocation"
    sf_hooks_fail "$SF_HOOK_ERROR"
    return 1
  fi
  REPLY=''
  reply=( "${decision[@]}" )
}

sf_hooks_commit_context() {
  local hook=$1 mode=${2-} context item script control control_json
  integer index
  SF_HOOK_CONTEXT_COUNT=0
  SF_HOOK_CONTEXT_RECORDS=()

  for (( index = 1; index <= ${#SF_HOOK_SCRIPT_RESULTS}; index += 5 )); do
    item=$SF_HOOK_SCRIPT_RESULTS[index+2]
    [[ -n $item ]] || continue
    script=${SF_HOOK_SCRIPT_RESULTS[index]:t}
    control=$SF_HOOK_SCRIPT_RESULTS[index+4]
    control_json=${control:-'{}'}
    context=$(print -rn -- "$item" |
      jq -Rsc -L "$SF_ROOT/lib" --arg hook "$hook" --arg script "$script" \
        --argjson control "$control_json" '
          include "runtime/schema";
          ({type:"context",hook:$hook,script:$script,content:.} +
            ($control.context // {})) as $context |
          if ($control.context? // {} | type == "object") and
              ($control.context? // {} | keys - ["prompt", "status"] | length) == 0 and
              ($context | canonical_context)
          then $context
          else error("invalid context control") end
        ') || {
      SF_HOOK_ERROR="hook script returned invalid context control: $script"
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

# Materializes the system record during session preparation.
sf_hooks_system() {
  local content item
  local -a parts
  integer index
  sf_hooks_run "$1" system '' allow reject 0 1 || return
  for (( index = 1; index <= ${#SF_HOOK_SCRIPT_RESULTS}; index += 5 )); do
    item=$SF_HOOK_SCRIPT_RESULTS[index+2]
    while [[ $item == *$'\n' ]]; do item=${item%$'\n'}; done
    [[ -z $item ]] || parts+=( "$item" )
    [[ -z $SF_HOOK_SCRIPT_RESULTS[index+3] ]] ||
      print -rn -u2 -- "$SF_HOOK_SCRIPT_RESULTS[index+3]"
  done
  content=${(pj:\n\n:)parts}
  if [[ -n $content ]]; then
    item=$(jq -cn --arg content "$content" '{type:"system",content:$content}') || {
      sf_hooks_fail 'cannot prepare system hook output'
      return
    }
    SF_SESSION_RECORDS+=( "$item" )
  fi
  reply=()
}

# Runs once during session preparation.
sf_hooks_session_start() {
  sf_hooks_run "$1" session_start '' commit reject 0 1 || return
  reply=()
}

# Prepares prompt context while exec retains the full-turn lock.
sf_hooks_user_prompt_submit_locked() {
  local prompt=$1 session=$2 argument control patch
  local -a decision handoff
  integer operation_status=0 index control_status handoff_requested=0 update_requested=0

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
  for (( index = 1; ! operation_status && index <= ${#SF_HOOK_SCRIPT_RESULTS}; index += 5 )); do
    control=$SF_HOOK_SCRIPT_RESULTS[index+4]
    [[ -n $control ]] || continue
    control_status=$SF_HOOK_SCRIPT_RESULTS[index+1]
    if ! jq -L "$SF_ROOT/lib" -e --argjson status "$control_status" '
          include "runtime/schema";
          (keys - ["action", "argv", "context", "patch"] | length) == 0 and
          (({type:"context",hook:"user_prompt_submit",script:"script",content:""} +
            (.context // {})) | canonical_context) and
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
      ' <<<"$control" >/dev/null; then
      SF_HOOK_ERROR='user_prompt_submit hook script returned invalid control data'
      operation_status=1
    elif (( control_status == 11 )) &&
        jq -e '.action? == "handoff"' <<<"$control" >/dev/null; then
      handoff_requested=1
      while IFS= read -r -d $'\0' argument; do
        handoff+=( "$argument" )
      done < <(jq -j '.argv[] | ., "\u0000"' <<<"$control")
    elif (( control_status == 11 )) &&
        jq -e '.action? == "session_update"' <<<"$control" >/dev/null; then
      update_requested=1
      patch=$(jq -c '.patch' <<<"$control") || operation_status=1
    fi
  done
  (( operation_status )) || sf_hooks_commit_context user_prompt_submit collect || operation_status=1
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
    for (( index = 1; index <= ${#SF_HOOK_SCRIPT_RESULTS}; index += 5 )); do
      [[ -z $SF_HOOK_SCRIPT_RESULTS[index+4] ]] || (( control_count += 1 ))
    done
    if (( control_count > 0 && (! result[2] || control_count != 1) )); then
      SF_HOOK_ERROR='permission_request hook script returned invalid decision'
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
        SF_HOOK_ERROR='permission_request hook script returned invalid decision'
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
    [[ -n $SF_HOOK_ERROR ]] || SF_HOOK_ERROR='cannot prepare permission_request hook script invocation'
    sf_hooks_fail "$SF_HOOK_ERROR"
    return 1
  fi
}

# Gates tool calls under the session lock and uses script output as denial feedback.
sf_hooks_pre_tool_use() {
  local session=$1 tool_name=$2 call_id=$3 tool_input=$4 input reason
  local -a decision feedback
  integer index

  if ! sf_hooks_configured pre_tool_use; then
    sf_hooks_require_lock pre_tool_use "$session" || return
    sf_hooks_reset
    reply=( allow '' )
    return 0
  fi
  input=$(print -rn -- "$tool_input" | jq -c --argjson turn_id "$SHELLFISH_TURN_ID" \
    --arg tool_name "$tool_name" --arg tool_use_id "$call_id" \
    '{turn_id:$turn_id,tool_name:$tool_name,tool_use_id:$tool_use_id,
      tool_input:.}') || {
    sf_hooks_fail 'cannot prepare pre-tool hook input'
    return
  }
  sf_hooks_run "$session" pre_tool_use "$input" allow allow 0 1 || return
  decision=( "${reply[@]}" )
  for (( index = 1; index <= ${#SF_HOOK_SCRIPT_RESULTS}; index += 5 )); do
    [[ -n $SF_HOOK_SCRIPT_RESULTS[index+2] ]] || continue
    if (( SF_HOOK_SCRIPT_RESULTS[index+1] == 0 )); then
      sf_hooks_fail 'pre_tool_use hook script wrote unsupported stdout'
      return 1
    fi
    feedback+=( "$SF_HOOK_SCRIPT_RESULTS[index+2]" )
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

  if ! sf_hooks_configured post_tool_use; then
    sf_hooks_require_lock post_tool_use "$session" || return
    sf_hooks_reset
    return 0
  fi
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
