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

sf_hooks_configured() {
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
  integer max_capture=$4 argument_count=$5
  shift 5
  local -a arguments=( "${(@)argv[1,argument_count]}" )
  local -a environment=( env -u SHELLFISH_API_KEY -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY )
  local context="$directory/current-context"
  local display="$directory/current-display"
  local display_pipe="$directory/current-display-pipe"
  local control="$directory/current-control"
  local HOOK_SCRIPT_ROOT=${script:h} hook=$SF_HOOK_NAME api_key_env
  local chunk notice=''
  integer script_status display_fd display_bytes=0 notice_sent=0
  local LC_ALL=C

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

  rm -f -- "$context" "$display" "$display_pipe" "$control"
  mkfifo "$display_pipe" || {
    sf_hooks_fail 'cannot prepare hook display capture'
    return
  }
  "${environment[@]}" "$script" "${arguments[@]}" \
    <"$input" >"$context" 2>"$display_pipe" 3>"$control" &
  integer script_pid=$!
  SF_HOOK_SCRIPT_PID=$script_pid
  exec {display_fd}<"$display_pipe" || {
    kill -KILL -- "-$script_pid" 2>/dev/null || kill -KILL "$script_pid" 2>/dev/null || true
    wait "$script_pid" 2>/dev/null || true
    SF_HOOK_SCRIPT_PID=''
    sf_hooks_fail 'cannot read hook display capture'
    return
  }
  : >"$display" || {
    exec {display_fd}<&-
    kill -KILL -- "-$script_pid" 2>/dev/null || kill -KILL "$script_pid" 2>/dev/null || true
    wait "$script_pid" 2>/dev/null || true
    SF_HOOK_SCRIPT_PID=''
    sf_hooks_fail 'cannot prepare hook display capture'
    return
  }
  while sysread -i $display_fd -s 4096 chunk; do
    print -rn -- "$chunk" >>"$display" || {
      exec {display_fd}<&-
      kill -KILL -- "-$script_pid" 2>/dev/null || kill -KILL "$script_pid" 2>/dev/null || true
      wait "$script_pid" 2>/dev/null || true
      SF_HOOK_SCRIPT_PID=''
      sf_hooks_fail 'cannot write hook display capture'
      return
    }
    (( display_bytes += ${#chunk} ))
    if (( ! notice_sent )); then
      notice+=$chunk
      if [[ $notice == *$'\n'* ]] && (( display_bytes <= max_capture )) &&
          (( $+functions[sf_run_hook_display_update] )); then
        notice=${notice%%$'\n'*}$'\n'
        sf_run_hook_display_update "$hook" "$script" "$notice" || {
          exec {display_fd}<&-
          kill -KILL -- "-$script_pid" 2>/dev/null || kill -KILL "$script_pid" 2>/dev/null || true
          wait "$script_pid" 2>/dev/null || true
          SF_HOOK_SCRIPT_PID=''
          sf_hooks_fail 'cannot emit hook display'
          return
        }
        notice_sent=1
      fi
    fi
  done
  exec {display_fd}<&-
  wait "$script_pid"
  script_status=$?
  SF_HOOK_SCRIPT_PID=''
  # Without a live event client, hook display is ordinary stderr.
  if (( display_bytes && display_bytes <= max_capture )); then
    if (( $+functions[sf_run_hook_display_complete] )); then
      sf_run_hook_display_complete "$hook" "$script" "$display" || {
        sf_hooks_fail 'cannot complete hook display'
        return
      }
    else
      cat "$display" >&2
    fi
  fi
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
      sf_hooks_capture_one "$script" "$input" "$directory" "$max_capture" \
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
      jq -Rsc -L "$SF_ROOT" --arg hook "$hook" --arg script "$script" \
        --argjson control "$control_json" '
          include "lib/runtime/schema";
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

# Runs once during session preparation.
sf_hooks_session_start() {
  sf_hooks_run "$1" session_start '' commit reject 0 1 || return
  reply=()
}
