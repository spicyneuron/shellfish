#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY="$SF_ROOT/bin/shellfish"

source "$SF_ROOT/lib/options.zsh"

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
  local requested_session='' input='' prompt='' arity='' input_projection
  local -a positional=() create_args=() input_fields
  integer session_explicit=0 jsonl=0 override=0 take=0

  while (( $# )); do
    case $1 in
      --session)
        (( ! session_explicit )) || { sf_die '--session may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session requires a nonempty path'; return 2; }
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
      --)
        shift
        positional+=( "$@" )
        break
        ;;
      -*)
        # config owns these; forward them unread. Selecting a config file is not
        # a runtime override.
        arity=${SF_CONFIG_OPTIONS[$1]-}
        [[ -n $arity ]] || { sf_die "unknown argument: $1"; return 2; }
        take=$(( arity + 1 ))
        (( $# >= take )) || { sf_die "$1 requires a value"; return 2; }
        create_args+=( "${@:1:$take}" )
        [[ $1 == --config ]] || override=1
        shift $take
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
    input_projection=$(jq -L "$SF_ROOT" -jre '
      include "lib/runtime/schema";
      def field: ., "\u0000";
      select(canonical_user_message) |
      (tojson | field), (.content[0].text | field), ("ok" | field)
    ' <<<"$input" 2>/dev/null) || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
    input_fields=( "${(@0)${input_projection%$'\0'}}" )
    (( ${#input_fields} == 3 )) && [[ $input_fields[3] == ok ]] || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
    input=$input_fields[1]
    prompt=$input_fields[2]
  else
    sf_run_prompt "${positional[@]}" || return
    prompt=$REPLY
    input=$(jq -cn --arg text "$prompt" \
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
  sf_run_turn "$input" "$session" "$jsonl" "$prompt"
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
