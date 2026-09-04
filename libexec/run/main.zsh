#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY="$SF_ROOT/bin/shellfish"

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_run_prompt() {
  local stdin_input=''
  if [[ ! -t 0 ]]; then stdin_input=$(<&0); fi
  if (( $# )); then
    [[ -z $stdin_input ]] || {
      sf_die 'cannot use a message argument and standard input together'
      return 2
    }
    stdin_input=${(j: :)@}
  fi
  [[ -n $stdin_input ]] || {
    sf_die 'a message is required for a new turn'
    return 2
  }
  REPLY=$stdin_input
}

sf_run_main() {
  local requested_session='' input=''
  local -a positional=() create_args=()
  integer session_explicit=0 jsonl=0 override=0

  while (( $# )); do
    case $1 in
      --session)
        (( $# >= 2 )) || {
          sf_die '--session requires a path'
          return 2
        }
        (( ! session_explicit )) || {
          sf_die '--session may only be specified once'
          return 2
        }
        [[ -n $2 ]] || {
          sf_die '--session requires a nonempty path'
          return 2
        }
        session_explicit=1
        requested_session=$2
        shift 2
        ;;
      --jsonl)
        jsonl=1
        shift
        ;;
      --verbose)
        sf_die 'shellfish run does not support --verbose'
        return 2
        ;;
      --sandbox-auto)
        create_args+=( "$1" )
        override=1
        shift
        ;;
      --)
        shift
        positional+=( "$@" )
        break
        ;;
      -*)
        # Options run does not own configure the session it creates, so they are
        # forwarded with any value. Use -- before a prompt that follows a
        # valueless option. Selecting a config file is not a runtime override.
        [[ $1 == --config ]] || override=1
        if (( $# >= 2 )) && [[ $2 != -* ]]; then
          create_args+=( "$1" "$2" )
          shift 2
        else
          create_args+=( "$1" )
          shift
        fi
        ;;
      *)
        positional+=( "$1" )
        shift
        ;;
    esac
  done

  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }
  # Trust an inherited verbose override only as the exact value chat exports.
  if [[ ${SHELLFISH_VERBOSE-0} == 1 ]]; then
    typeset -gx SHELLFISH_VERBOSE=1
  else
    typeset -gx SHELLFISH_VERBOSE=0
  fi

  if (( jsonl )); then
    (( ! ${#positional} )) || {
      sf_die '--jsonl does not accept a prompt'
      return 2
    }
    IFS= read -r input || [[ -n $input ]] || input=''
    [[ -n $input ]] || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
    input=$(jq -L "$SF_ROOT" -ce '
      include "lib/runtime/schema";
      select(canonical_user_message)
    ' <<<"$input" 2>/dev/null) || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
  else
    sf_run_prompt "${positional[@]}" || return
    input=$(jq -cn --arg text "$REPLY" \
      '{type:"message",role:"user",content:[{type:"text",text:$text}]}') || return 1
  fi

  source "$SF_ROOT/lib/session/startup.zsh"
  sf_session_open "$requested_session" "$override" '' "${create_args[@]}"
  local open_status=$?
  if (( open_status )); then
    [[ -z $SF_SESSION_STARTUP_ERROR ]] || sf_die "$SF_SESSION_STARTUP_ERROR"
    return $open_status
  fi

  local session=$SF_SESSION_OPEN[path] failure=''
  source "$SF_ROOT/libexec/run/turn.zsh"
  SF_RUN[jsonl]=$jsonl
  if [[ -e $session && ( ! -f $session || -L $session ) ]]; then
    failure="invalid session path: $session"
  elif [[ ! -s $session ]]; then
    failure="no session at: $session"
  fi
  if [[ -n $failure ]]; then
    if (( jsonl )); then
      sf_run_error "$failure"
    else
      sf_die "$failure"
    fi
    return 1
  fi

  typeset -gx SHELLFISH_MODE=run
  trap 'SF_RUN[signal_status]=130; kill -TERM $$' INT
  trap 'SF_RUN[signal_status]=129; kill -TERM $$' HUP
  trap 'sf_run_interrupt; exit $SF_RUN[signal_status]' TERM
  # Only a JSONL client can answer a permission request on stdin.
  sf_run_turn "$input" "$session" "$jsonl"
  local run_status=$?
  trap - INT HUP TERM
  if (( ! jsonl )) && [[ -n $SF_RUN[answer] ]]; then
    print -r -- "$SF_RUN[answer]"
  fi
  return $run_status
}

sf_run_main "$@"
typeset exit_status=$?
exit $exit_status
