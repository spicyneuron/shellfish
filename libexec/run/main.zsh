#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY="$SF_ROOT/bin/shellfish"

source "$SF_ROOT/lib/cli.zsh"
source "$SF_ROOT/lib/jq.zsh"
source "$SF_ROOT/lib/options.zsh"

sf_run_main() {
  local requested_session='' input='' prompt='' arity=''
  local -a positional=() create_args=()
  local -a background_launcher=()
  local -A message
  integer create_only=0 json=0 jsonl=0 background=0 override=0 take=0

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
      --json)
        json=1
        shift
        ;;
      --jsonl)
        jsonl=1
        shift
        ;;
      --background)
        background=1
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
        # Creation owns these; every one of them overrides the profile.
        arity=${SF_CREATE_OPTIONS[$1]-}
        [[ -n $arity ]] || { sf_die "unknown argument: $1"; return 2; }
        take=$(( arity + 1 ))
        (( $# >= take )) || { sf_die "$1 requires a value"; return 2; }
        create_args+=( "${@:1:$take}" )
        override=1
        shift $take
        ;;
      *)
        positional+=( "$1" )
        shift
        ;;
    esac
  done

  (( ! json || ! jsonl )) || {
    sf_die '--json and --jsonl cannot be combined'
    return 2
  }
  (( ! background || ! json )) || { sf_die '--background cannot be combined with --json'; return 2; }
  (( ! background || ! jsonl )) || { sf_die '--background cannot be combined with --jsonl'; return 2; }
  (( ! background || ! create_only )) || { sf_die '--background cannot be combined with --session-create'; return 2; }
  if (( background )); then
    source "$SF_ROOT/lib/process.zsh"
    sf_process_isolation_launcher || {
      sf_die '--background requires macOS /usr/bin/script or Linux setsid'
      return 2
    }
    background_launcher=( "${reply[@]}" )
  fi
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
    if [[ -n ${SHELLFISH_BACKGROUND_WORKER-} && -n ${SHELLFISH_BACKGROUND_INPUT-} ]]; then
      input=$(<"$SHELLFISH_BACKGROUND_INPUT") || { sf_die 'cannot read background input'; return 1; }
      rm -f -- "$SHELLFISH_BACKGROUND_INPUT"
      unset SHELLFISH_BACKGROUND_INPUT
    else
      IFS= read -r input || [[ -n $input ]] || input=''
    fi
    [[ -n $input ]] || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
    sf_jq_fields -re '
      include "lib/fields";
      include "lib/session";
      select(canonical_user_message) |
      entry("record"; tojson), entry("prompt"; .content[0].text), ("ok" | field)
    ' <<<"$input" || {
      sf_die '--jsonl requires a canonical user message on stdin'
      return 2
    }
    message=( "${reply[@]}" )
    input=$message[record]
    prompt=$message[prompt]
  else
    sf_cli_read_prompt "${positional[@]}" || return
    prompt=$REPLY
    [[ -n $prompt ]] || {
      sf_die 'a message is required for a new turn'
      return 2
    }
    input=$(jq -cn --arg text "$prompt" \
      '{type:"user",content:[{type:"text",text:$text}]}') || return 1
  fi

  source "$SF_ROOT/libexec/run/turn.zsh"
  SF_RUN[jsonl]=$jsonl
  typeset -gx SHELLFISH_MODE=run
  trap 'SF_RUN[signal_status]=130; kill -TERM $$' INT USR1
  if [[ -n ${SHELLFISH_BACKGROUND_WORKER-} ]]; then
    trap '' HUP
  else
    trap 'SF_RUN[signal_status]=129; kill -TERM $$' HUP
  fi
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
  if (( background )); then
    trap - INT USR1 HUP TERM
    local input_file ack_dir ack_file
    input_file=$(mktemp "${TMPDIR:-/tmp}/shellfish-background-input.XXXXXX") || return 1
    ack_dir=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-background-ack.XXXXXX") || {
      rm -f -- "$input_file"
      return 1
    }
    ack_file="$ack_dir/ready"
    print -r -- "$input" >"$input_file" && mkfifo "$ack_file" || {
      rm -f -- "$input_file" "$ack_file"
      rmdir "$ack_dir"
      sf_die 'cannot prepare background turn'
      return 1
    }
    exec 4<>"$ack_file" || {
      rm -f -- "$input_file" "$ack_file"
      rmdir "$ack_dir"
      sf_die 'cannot prepare background acknowledgement'
      return 1
    }
    SHELLFISH_BACKGROUND_WORKER=1 SHELLFISH_BACKGROUND_INPUT="$input_file" \
      "${background_launcher[@]}" "$commands[zsh]" -f -c \
      'trap "" HUP; exec "$@" </dev/null >/dev/null 2>&1 3>&-' -- \
      "$SF_ROOT/libexec/run/main.zsh" --jsonl --session "$session" \
      </dev/null >/dev/null 2>&1 3>&- 4>&4 &!
    local launch_pid=$!
    local acknowledgement=''
    if read -r -t 10 -u 4 acknowledgement && [[ $acknowledgement == ready ]]; then
      exec 4>&-
      rm -f -- "$ack_file"
      rmdir "$ack_dir"
      print -r -- "$session"
      return 0
    fi
    exec 4>&-
    rm -f -- "$ack_file"
    rmdir "$ack_dir"
    kill -0 "$launch_pid" 2>/dev/null || rm -f -- "$input_file"
    sf_die 'background worker did not acknowledge start'
    return 1
  fi
  if [[ -n ${SHELLFISH_BACKGROUND_WORKER-} ]]; then
    print -r -u 4 -- ready || return 1
    exec 4>&-
    unset SHELLFISH_BACKGROUND_WORKER
  fi
  sf_run_turn "$input" "$session" "$prompt"
  local run_status=$?
  trap - INT USR1 HUP TERM
  if (( json )) && [[ -n $SF_RUN[assistant] ]]; then
    jq -c --arg message "$SF_RUN[answer]" \
      '{message:$message,stop:.stop,usage:(.usage // null)}' \
      <<<"$SF_RUN[assistant]" || { sf_die 'cannot format final response'; return 1; }
  elif (( ! jsonl )) && [[ -n $SF_RUN[answer] ]]; then
    print -r -- "$SF_RUN[answer]"
  fi
  return $run_status
}

sf_run_main "$@"
typeset exit_status=$?
exit $exit_status
