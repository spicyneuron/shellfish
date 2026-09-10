emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_category] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_environment_prepare] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_capture] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_state_control_decode] )) || source "$SF_ROOT/lib/state.zsh"

typeset -g SF_HOOK_ERROR=''
typeset -g SF_HOOK_JSONL=0
typeset -g SF_HOOK_DISPLAY=1
typeset -g SF_HOOK_ERROR_EMITTED=0
typeset -g SF_HOOK_COMPONENT_VALIDATOR=''
# Preserve inherited turn state across nested turn setup.
typeset -g SHELLFISH_TURN_STATE=${SHELLFISH_TURN_STATE-}
typeset -g SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
typeset -g SF_HOOK_NAME=''
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
  REPLY=''
  reply=()
}

sf_hooks_fail() {
  local error=$1
  sf_hooks_reset
  SF_HOOK_ERROR=$error
  return 1
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

sf_hooks_start() {
  local hook=$1 script=$2 text=$3
  (( SF_HOOK_DISPLAY && SF_HOOK_JSONL )) || return 0
  jq -cn --arg hook "$hook" --arg script "$script" --arg text "$text" \
    '{type:"_hook_start",hook:$hook,script:$script,text:$text}' || return
}

sf_hooks_end() {
  local text=$1 error=$2 display=$3
  (( SF_HOOK_DISPLAY )) || return 0
  if (( ! SF_HOOK_JSONL )); then
    [[ -z $display ]] || print -rn -- "$display" >&2
    return 0
  fi
  print -rn -- "$text" | jq -Rsc --argjson error "$error" \
    '{type:"_hook_end",text:.,error:$error}'
}

sf_hooks_append() {
  local session=$1 record=$2
  sf_session_append "$session" "$record" || {
    SF_HOOK_ERROR=$SF_SESSION_ERROR
    return 1
  }
  if (( SF_HOOK_JSONL )) && ! print -r -- "$record"; then
    SF_HOOK_ERROR='cannot emit hook record'
    return 1
  fi
}

sf_hooks_active_fail() {
  local error=$1 display=${2-}
  if (( SF_HOOK_DISPLAY )); then
    SF_HOOK_ERROR_EMITTED=1
    sf_hooks_end "$error" true "$display" || error='cannot complete hook display'
  elif [[ -n $display ]]; then
    error+=": $display"
  fi
  sf_hooks_fail "$error"
}

sf_hooks_capture_one() {
  local script=$1 input=$2 directory=$3
  setopt local_options no_monitor
  integer max_capture=$4 argument_count=$5
  local environment_json=$6
  shift 6
  local -a arguments=( "${(@)argv[1,argument_count]}" )
  local -a environment=( env )
  local hook=$SF_HOOK_NAME name value
  local -a fixed_names=(
    SHELLFISH_SESSION SHELLFISH_MAX_CAPTURE_BYTES SHELLFISH_MODEL
    SHELLFISH_EXECUTABLE SHELLFISH_MODE
    SHELLFISH_VERBOSE SHELLFISH_CONFIG_DIR SHELLFISH_TURN_ID SHELLFISH_TURN_STATE
  )
  local LC_ALL=C

  [[ -n $hook ]] || {
    sf_hooks_fail 'hook name is not available'
    return
  }
  sf_environment_prepare "$SF_SESSION[runtime]" "$environment_json" || {
    sf_hooks_fail "$SF_ENVIRONMENT_ERROR"
    return
  }
  for name in $SF_ENVIRONMENT_NAMES; do
    environment+=( -u "$name" )
  done
  for value in $SF_ENVIRONMENT_VALUES; do
    name=${value%%=*}
    (( ${fixed_names[(Ie)$name]} )) || environment+=( "$value" )
  done
  for name in $fixed_names; do
    [[ ${parameters[$name]-} == *export* ]] || continue
    environment+=( "$name=${(P)name}" )
  done

  sf_process_capture "$input" "$directory" "$PWD" separate \
    $max_capture "${environment[@]}" "$script" "${arguments[@]}" || {
      sf_hooks_fail 'cannot capture hook script output'
      return
    }
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
  local -a components=( "$@" ) result component_states decoded
  local directory script script_name selector environment_json label record context_record context_control
  local script_context script_display script_control hook=$SF_HOOK_NAME
  local origin='' control='' control_error
  local stdout_policy=$SF_HOOK_STDOUT_POLICY
  local skip_policy=$SF_HOOK_SKIP_POLICY
  integer script_status selector_status context_size display_size control_size component_index has_context=0
  integer perform=1 halted=0
  setopt local_options no_err_exit no_bg_nice

  sf_hooks_reset
  (( ${#components} % 4 == 0 )) || {
    sf_hooks_fail 'cannot inspect configured hook components'
    return
  }

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

    for (( component_index = 1; component_index <= ${#components}; component_index += 4 )); do
      script=$components[component_index]
      label=$components[component_index+1]
      selector=$components[component_index+2]
      environment_json=$components[component_index+3]
      component_states=()
      if [[ -n $selector ]]; then
        sf_hooks_capture_one "$selector" "$input" "$directory" "$max_capture" \
          "$argument_count" "$environment_json" "${arguments[@]}" || return
        result=( "${reply[@]}" )
        selector_status=$result[1]
        if [[ -s $result[2] || -s $result[3] || -s $result[4] ]]; then
          sf_hooks_fail "hook match command wrote output: $selector"
          return
        fi
        case $selector_status in
          0) ;;
          1) continue ;;
          *)
            sf_hooks_fail "hook match command failed with status $selector_status: $selector"
            return
            ;;
        esac
      fi
      script_name=$script
      [[ ${script_name:t} != run ]] || script_name=${script_name:h}
      script_name=${script_name:t}
      sf_hooks_start "$hook" "$script_name" "$label" || {
        sf_hooks_fail 'cannot open hook display'
        return
      }
      sf_hooks_capture_one "$script" "$input" "$directory" "$max_capture" \
        "$argument_count" "$environment_json" "${arguments[@]}" || {
        sf_hooks_active_fail "$SF_HOOK_ERROR"
        return
      }
      result=( "${reply[@]}" )
      script_status=$result[1]

      context_size=$(wc -c <"$result[2]") || {
        sf_hooks_active_fail "cannot inspect hook script context: $script"
        return
      }
      display_size=$(wc -c <"$result[3]") || {
        sf_hooks_active_fail "cannot inspect hook script display: $script"
        return
      }
      control_size=$(wc -c <"$result[4]") || {
        sf_hooks_active_fail "cannot inspect hook script control: $script"
        return
      }
      (( context_size + display_size + control_size <= max_capture )) || {
        sf_hooks_active_fail "hook script output exceeds capture limit: $script"
        return
      }

      sf_hooks_read_capture "$result[2]" "$context_size" || {
        sf_hooks_active_fail "cannot read hook script context: $script"
        return
      }
      script_context=$REPLY
      sf_hooks_read_capture "$result[3]" "$display_size" || {
        sf_hooks_active_fail "cannot read hook script display: $script"
        return
      }
      script_display=$REPLY
      script_control=''
      control_error=''
      case $script_status in
        0|10|11) ;;
        *)
          control_error="hook script failed with status $script_status: $script"
          if (( SF_HOOK_DISPLAY )) && [[ -n $script_display ]]; then
            control_error+=": $script_display"
          fi
          ;;
      esac
      if [[ -z $control_error ]] && (( control_size )); then
        sf_state_control_decode "$result[4]" || {
          if [[ $REPLY == malformed ]]; then
            control_error='hook script returned malformed control data'
          else
            control_error="hook script returned invalid state control: $script"
          fi
        }
        if [[ -z $control_error ]]; then
          decoded=( "${reply[@]}" )
          script_control=$decoded[1]
          component_states=( "${(@)decoded[2,-1]}" )
        fi
      fi
      if [[ -z $control_error && -n $script_control ]] && (( ! allow_control )); then
        control_error="hook script returned unexpected control data: $script"
      fi
      if [[ -z $control_error && $stdout_policy == reject && -n $script_context ]]; then
        control_error="$hook hook script wrote unsupported stdout"
      fi
      if [[ -z $control_error && $skip_policy == reject && $script_status != 0 ]]; then
        control_error="$hook hook script returned unsupported skip status"
      fi
      if [[ -z $control_error && -n $SF_HOOK_COMPONENT_VALIDATOR ]]; then
        "$SF_HOOK_COMPONENT_VALIDATOR" "$script" "$script_status" \
          "$script_context" "$script_control" || control_error=$SF_HOOK_ERROR
      fi
      if [[ -n $control_error ]]; then
        sf_hooks_active_fail "$control_error" "$script_display"
        return
      fi
      context_record=''
      if [[ -n $script_context ]] && { [[ $stdout_policy == commit ]] ||
          [[ $stdout_policy == commit_on_skip && $script_status != 0 ]]; }; then
        context_control=${script_control:-'{}'}
        sf_hooks_context_record "$hook" "$script_name" "$script_context" \
          "$context_control" || {
          sf_hooks_active_fail "$SF_HOOK_ERROR" "$script_display"
          return
        }
        context_record=$REPLY
        has_context=1
      fi
      for record in "${component_states[@]}"; do
        if [[ -n ${SF_HOOK_SESSION-} ]]; then
          sf_hooks_append "$SF_HOOK_SESSION" "$record" || {
            sf_hooks_active_fail "$SF_HOOK_ERROR" "$script_display"
            return
          }
        fi
      done
      if [[ -n $context_record ]]; then
        if [[ -n ${SF_HOOK_SESSION-} ]]; then
          sf_hooks_append "$SF_HOOK_SESSION" "$context_record" || {
            sf_hooks_active_fail "$SF_HOOK_ERROR" "$script_display"
            return
          }
        fi
      fi
      sf_hooks_end "${script_display:-$script_context}" false "$script_display" || {
        sf_hooks_fail 'cannot complete hook display'
        return
      }
      [[ -z $script_control ]] || control=$script_control
      if (( script_status == 10 || script_status == 11 )); then
        [[ -n $origin ]] || origin=$script
        perform=0
      fi
      if (( script_status == 11 )); then
        halted=1
        break
      fi
    done

    if (( ! perform )) && [[ $skip_policy == require_context ]] && (( ! has_context )); then
      sf_hooks_fail "$hook hook script skipped completion without feedback"
      return
    fi
  } always {
    rm -rf -- "$directory" 2>/dev/null || true
  }
  REPLY=''
  reply=( "$perform" "$halted" "$origin" "$control" )
}

sf_hooks_turn_state_create() {
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
  local SHELLFISH_MAX_CAPTURE_BYTES=$max_capture
  local SHELLFISH_MODEL=${SHELLFISH_MODEL:-$SF_SESSION[model]}
  local SHELLFISH_EXECUTABLE=${SF_ENTRY-}
  local SHELLFISH_CONFIG_DIR=${SHELLFISH_CONFIG_DIR-}
  local SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
  local SF_HOOK_NAME=$hook
  export SHELLFISH_SESSION SHELLFISH_MAX_CAPTURE_BYTES SHELLFISH_MODEL
  export SHELLFISH_EXECUTABLE SHELLFISH_CONFIG_DIR
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
  local -a fields components input_option=( --arg input '' )

  [[ $hook != user_prompt_submit ]] || input_option=( --rawfile input "$input" )

  # The terminator keeps a trailing empty environment field, which command
  # substitution would otherwise strip along with the final newline.
  fields=( "${(@f)$(jq -erc --arg hook "$hook" "${input_option[@]}" '
    .harness.max_capture_bytes,
    (.harness[$hook][]? | . as $component |
      select(($component.match.pattern? // "") == "" or
        ($input | test($component.match.pattern))) |
      .command, .display, (.match.command? // ""), (.environment | join(" "))),
    "ok"
  ' <<<"$SF_SESSION[runtime]")}" ) || return 1
  [[ $fields[-1] == ok ]] || return 1
  components=( "${(@)fields[2,-2]}" )
  local SHELLFISH_MODEL=$SF_SESSION[model]
  local SHELLFISH_CONFIG_DIR=''
  sf_environment_project "$SF_SESSION[runtime]" || return 1
  [[ -z $SF_ENVIRONMENT_FILE ]] || SHELLFISH_CONFIG_DIR=${SF_ENVIRONMENT_FILE:h}
  sf_hooks_invoke "$session" "$SF_SESSION[cwd]" "$input" "$fields[1]" \
    "$allow_control" "$argument_count" "$hook" "$@" "${components[@]}"
}

sf_hooks_run() {
  local session=$1 hook=$2 content=$3 stdout_policy=$4 skip_policy=$5
  integer allow_control=$6 argument_count=$7 operation_status=0
  shift 7
  local input label=$hook
  local -a decision
  local SF_HOOK_SESSION=$session
  local SF_HOOK_STDOUT_POLICY=$stdout_policy
  local SF_HOOK_SKIP_POLICY=$skip_policy
  [[ $hook != pre_tool_use ]] || label=pre-tool

  SF_HOOK_ERROR=''
  (( ${+SF_HOOK_COUNTS[$hook]} )) || {
    sf_hooks_fail "unknown hook: $hook"
    return
  }
  if (( ! SF_HOOK_COUNTS[$hook] )); then
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

sf_hooks_context_record() {
  local hook=$1 script=$2 item=$3 control=$4
  REPLY=$(print -rn -- "$item" |
    sf_jq -Rsc --arg hook "$hook" --arg script "$script" \
      --argjson control "$control" '
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
}

# Runs once during session preparation.
sf_hooks_session_start() {
  sf_hooks_run "$1" session_start '' commit reject 0 1 || return
  reply=()
}
