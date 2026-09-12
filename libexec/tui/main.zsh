#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY=$SF_ROOT/bin/shellfish
typeset -gr SF_TUI_ENTRY=${0:A}

source "$SF_ROOT/lib/options.zsh"

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_read_prompt() {
  local input=''
  if [[ ! -t 0 ]]; then input=$(<&0); fi
  if (( $# )); then
    [[ -z $input ]] || {
      sf_die 'cannot use a message argument and standard input together'
      return 2
    }
    input=${(j: :)@}
  fi
  REPLY=$input
}

sf_tui_main() {
  local requested_session=''
  local input='' draft='' presentation session='' session_mode=startup
  local arity=''
  local -a positional=() runtime_args=() presentation_args=()
  local -a original_args=("$@")
  integer out_explicit=0 override=0 take=0
  integer clear_requested=0
  integer handoff=0 draft_explicit=0
  integer verbose_requested=0 controller_status=0

  while (( $# )); do
    case $1 in
      -s|--session)
        [[ -z $requested_session ]] || { sf_die '--session may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session requires a nonempty path'; return 2; }
        requested_session=$2
        shift 2
        ;;
      --session-out)
        (( ! out_explicit )) || { sf_die '--session-out may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session-out requires a nonempty path'; return 2; }
        out_explicit=1
        runtime_args+=( "${@:1:2}" )
        shift 2
        ;;
      --clear)
        clear_requested=1
        shift
        ;;
      --draft)
        (( $# >= 2 )) || { sf_die '--draft requires text'; return 2; }
        (( ! draft_explicit )) || { sf_die '--draft may only be specified once'; return 2; }
        draft_explicit=1
        draft=$2
        shift 2
        ;;
      --verbose)
        verbose_requested=1
        presentation_args+=( "$1" )
        shift
        ;;
      --)
        shift
        positional+=( "$@" )
        break
        ;;
      -*)
        # Creation owns these; forward them unread. Selecting a config file is
        # not a runtime override, and chat also reports presentation from it.
        arity=${SF_CREATE_OPTIONS[$1]-}
        [[ -n $arity ]] || { sf_die "unknown argument: $1"; return 2; }
        take=$(( arity + 1 ))
        (( $# >= take )) || { sf_die "$1 requires a value"; return 2; }
        runtime_args+=( "${@:1:$take}" )
        if [[ $1 == --config ]]; then
          presentation_args+=( "${@:1:$take}" )
        else
          override=1
        fi
        shift $take
        ;;
      *)
        positional+=( "$1" )
        shift
        ;;
    esac
  done

  [[ -z $requested_session ]] || (( ! out_explicit )) || {
    sf_die '--session names an existing session and cannot be combined with --session-out'
    return 2
  }
  if [[ ! -o interactive && -t 1 && ( -t 0 || -r /dev/tty ) ]]; then handoff=1; fi
  (( $+commands[jq] )) || { sf_die 'shellfish requires jq'; return 2; }
  typeset -gx SHELLFISH_VERBOSE=$verbose_requested

  sf_read_prompt "${positional[@]}" || return
  input=$REPLY
  if (( draft_explicit )) && { (( ${#positional} )) || [[ -n $input ]]; }; then
    sf_die '--draft cannot be combined with a prompt'
    return 2
  fi
  if (( handoff )); then
    if [[ -n $input && ! ${#positional} ]]; then
      exec zsh -f -i "$SF_TUI_ENTRY" "${original_args[@]}" <<<"$input"
    fi
    exec zsh -f -i "$SF_TUI_ENTRY" "${original_args[@]}"
  fi
  if [[ ! -o interactive ]]; then
    sf_die 'chat requires an interactive terminal'
    return 2
  fi
  if [[ ! -t 0 ]]; then
    exec </dev/tty || { sf_die 'chat requires an interactive terminal'; return 2; }
  fi
  if [[ ! -t 1 ]]; then sf_die 'chat requires an interactive terminal'; return 2; fi

  integer startup_status=0 config_status=0
  if [[ -n $requested_session ]]; then
    source "$SF_ROOT/lib/session/startup.zsh"
    sf_session_open "$requested_session" "$override" \
      "${runtime_args[@]}" || startup_status=$?
    if (( startup_status )); then
      [[ -z $SF_SESSION_STARTUP_ERROR ]] || sf_die "$SF_SESSION_STARTUP_ERROR"
      return $startup_status
    fi
    session=$SF_SESSION_OPEN[path]
    session_mode=resume
    presentation_args=( --session-from "$session" "${presentation_args[@]}" )
  fi
  # Presentation is never frozen, so chat resolves it per start for either mode.
  presentation=$("$SF_ENTRY" config "${presentation_args[@]}") || config_status=$?
  (( ! config_status )) || return $config_status

  source "$SF_ROOT/libexec/tui/render/main.zsh"
  source "$SF_ROOT/libexec/tui/transport.zsh"
  source "$SF_ROOT/libexec/tui/editor.zsh"
  source "$SF_ROOT/libexec/tui/controller.zsh"
  if [[ $session_mode == startup ]]; then
    SF_TUI_TRANSPORT_COMMAND=( "$SF_ENTRY" create --jsonl "${runtime_args[@]}" )
  else
    SF_TUI_TRANSPORT_COMMAND=( "$SF_ENTRY" run --jsonl --session "$session" )
  fi
  if (( clear_requested )); then
    zmodload zsh/terminfo && echoti clear || { sf_die 'cannot clear terminal'; return 1; }
  fi
  {
    sf_tui_controller "$session" "$presentation" "$input" \
      "$session_mode" "$draft" || controller_status=$?
  } always {
    [[ -z $SF_TUI_TRANSPORT_PID ]] || sf_tui_transport_stop
  }
  if (( controller_status )); then
    [[ -z $SF_PRESENT_ERROR ]] || sf_die "$SF_PRESENT_ERROR"
    return $controller_status
  fi
}

sf_tui_main "$@"
typeset exit_status=$?
exit $exit_status
