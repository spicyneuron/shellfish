#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY="$SF_ROOT/bin/shellfish"

source "$SF_ROOT/lib/jq.zsh"
source "$SF_ROOT/lib/options.zsh"

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

# An inherited pipe may never reach EOF, so only a turn that needs the message
# reads until it closes.
sf_run_prompt() {
  local stdin_input=''
  if (( $# )); then
    if [[ ! -t 0 ]]; then IFS= read -t 0 -r stdin_input || true; fi
    [[ -z $stdin_input ]] || {
      sf_die 'cannot use a message argument and standard input together'
      return 2
    }
    stdin_input=${(j: :)@}
  elif [[ ! -t 0 ]]; then
    stdin_input=$(<&0)
  fi
  [[ -n $stdin_input ]] || {
    sf_die 'a message is required for a new turn'
    return 2
  }
  REPLY=$stdin_input
}

sf_run_main() {
  local requested_session='' input='' prompt='' arity=''
  local -a positional=() create_args=()
  integer create_only=0 jsonl=0 override=0 take=0

  while (( $# )); do
    case $1 in
      -s|--session)
        [[ -z $requested_session ]] || { sf_die '--session may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session requires a nonempty path'; return 2; }
        requested_session=$2
        shift 2
        ;;
      --session-out)
        # Creation owns the value diagnostics.
        (( $# >= 2 )) || { sf_die '--session-out requires a value'; return 2; }
        override=1
        create_args+=( "${@:1:2}" )
        shift 2
        ;;
      --jsonl)
        jsonl=1
        shift
        ;;
      --session-create)
        (( ! create_only )) || { sf_die '--session-create may only be specified once'; return 2; }
        create_only=1
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
        # Creation owns these; only --config is not an override.
        arity=${SF_CREATE_OPTIONS[$1]-}
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

  if (( create_only )); then
    [[ -z $requested_session ]] || {
      sf_die '--session-create cannot be combined with --session'
      return 2
    }
    (( ! ${#positional} )) || {
      sf_die '--session-create does not accept a prompt'
      return 2
    }
    if [[ ! -t 0 ]]; then IFS= read -t 0 -r input || true; fi
    [[ -z $input ]] || {
      sf_die '--session-create does not accept a prompt'
      return 2
    }
  fi
  [[ -z $requested_session ]] || (( ! override )) || {
    sf_die 'options that configure a new session cannot be used with an existing one'
    return 2
  }
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }
  # Trust only an inherited SHELLFISH_VERBOSE=1.
  if [[ ${SHELLFISH_VERBOSE-0} == 1 ]]; then
    typeset -gx SHELLFISH_VERBOSE=1
  else
    typeset -gx SHELLFISH_VERBOSE=0
  fi

  if (( create_only )); then
    input=''
  elif (( jsonl )); then
    (( ! ${#positional} )) || {
      sf_die '--jsonl does not accept a prompt'
      return 2
    }
    IFS= read -r input || [[ -n $input ]] || input=''
    [[ -n $input ]] || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
    sf_jq_fields 2 -re '
      include "lib/session";
      def field: ., "\u0000";
      select(canonical_user_message) |
      (tojson | field), (.content[0].text | field), ("ok" | field)
    ' <<<"$input" || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
    input=$reply[1]
    prompt=$reply[2]
  else
    sf_run_prompt "${positional[@]}" || return
    prompt=$REPLY
    input=$(jq -cn --arg text "$prompt" \
      '{type:"user",content:[{type:"text",text:$text}]}') || return 1
  fi

  source "$SF_ROOT/libexec/run/turn.zsh"
  SF_RUN[jsonl]=$jsonl
  typeset -gx SHELLFISH_MODE=run
  trap 'SF_RUN[signal_status]=130; kill -TERM $$' INT USR1
  trap 'SF_RUN[signal_status]=129; kill -TERM $$' HUP
  trap '(( SF_RUN[signal_status] )) || SF_RUN[signal_status]=143;
    sf_run_interrupt "$SF_RUN[signal_status]"; exit $SF_RUN[signal_status]' TERM
  local session
  if [[ -n $requested_session ]]; then
    sf_session_select_path "$requested_session" || { sf_die "$SF_SESSION_ERROR"; return 1; }
    session=$REPLY
    [[ -s $session ]] || { sf_die "no session at $session"; return 1; }
  else
    source "$SF_ROOT/libexec/run/create.zsh"
    local create_status=0
    sf_run_create "${create_args[@]}" || create_status=$?
    if (( create_status )); then
      if (( create_status == 130 )); then
        sf_die 'Cancelled.' || true
      elif (( create_status == 129 || create_status == 143 )); then
        sf_die 'Session creation interrupted.' || true
      fi
      return $create_status
    fi
    session=$REPLY
  fi
  if (( create_only )); then
    trap - INT USR1 HUP TERM
    return 0
  fi
  sf_run_turn "$input" "$session" "$prompt"
  local run_status=$?
  trap - INT USR1 HUP TERM
  if (( ! jsonl )) && [[ -n $SF_RUN[answer] ]]; then
    print -r -- "$SF_RUN[answer]"
  fi
  return $run_status
}

sf_run_main "$@"
typeset exit_status=$?
exit $exit_status
