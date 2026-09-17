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
  local input='' draft='' presentation runtime session='' session_mode=startup
  local presentation_config='' source_session=''
  local arity=''
  local -a positional=() runtime_args=() resolve_args=()
  local -a original_args=("$@")
  integer out_explicit=0 override=0 runtime_override=0 take=0
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
        shift
        ;;
      --)
        shift
        positional+=( "$@" )
        break
        ;;
      -*)
        arity=${SF_CREATE_OPTIONS[$1]-}
        [[ -n $arity ]] || { sf_die "unknown argument: $1"; return 2; }
        take=$(( arity + 1 ))
        (( $# >= take )) || { sf_die "$1 requires a value"; return 2; }
        runtime_args+=( "${@:1:$take}" )
        # The banner and footer describe the runtime creation will freeze, so
        # the client resolves the same options. Only the system prompt is its own.
        [[ $1 == (--system|--system-file|--session-from) ]] ||
          resolve_args+=( "${@:1:$take}" )
        [[ $1 != --config ]] || presentation_config=$2
        [[ $1 != --session-from ]] || source_session=$2
        [[ $1 == (--config|--system|--system-file|--session-from) ]] || runtime_override=1
        [[ $1 == --config ]] || override=1
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

  integer resolve_status=0
  if [[ -n $requested_session ]]; then
    (( ! override )) || {
      sf_die 'options that configure a new session cannot be used with an existing one'
      return 2
    }
    source "$SF_ROOT/lib/session.zsh"
    sf_session_select_path "$requested_session" || {
      sf_die "$SF_SESSION_ERROR"
      return 1
    }
    session=$REPLY
    session_mode=resume
  fi
  source "$SF_ROOT/lib/runtime.zsh"
  SF_RUNTIME_VERBOSE=$verbose_requested
  if [[ $session_mode == resume ]]; then
    sf_session_read_runtime "$session" || {
      sf_die "$SF_SESSION_ERROR"
      return 1
    }
    runtime=$REPLY
    sf_runtime_restore_presentation "$presentation_config" || {
      resolve_status=$?
      sf_die "$SF_RUNTIME_ERROR"
      return $resolve_status
    }
  elif [[ -n $source_session ]]; then
    (( ! runtime_override )) || {
      sf_die 'runtime overrides cannot be used with --session-from'
      return 2
    }
    source "$SF_ROOT/lib/session.zsh"
    sf_session_select_path "$source_session" || {
      sf_die "$SF_SESSION_ERROR"
      return 1
    }
    sf_session_read_runtime "$REPLY" || {
      sf_die "$SF_SESSION_ERROR"
      return 1
    }
    runtime=$REPLY
    sf_runtime_restore_presentation "$presentation_config" || {
      resolve_status=$?
      sf_die "$SF_RUNTIME_ERROR"
      return $resolve_status
    }
  else
    sf_runtime_resolve_args "${resolve_args[@]}" || {
      resolve_status=$?
      sf_die "$SF_RUNTIME_ERROR"
      return $resolve_status
    }
    runtime=$REPLY
  fi
  presentation=$SF_PRESENTATION

  source "$SF_ROOT/libexec/tui/render/main.zsh"
  source "$SF_ROOT/libexec/tui/project.zsh"
  source "$SF_ROOT/libexec/tui/transport.zsh"
  source "$SF_ROOT/libexec/tui/editor.zsh"
  source "$SF_ROOT/libexec/tui/controller.zsh"
  if [[ $session_mode == startup ]]; then
    SF_TUI_TRANSPORT_COMMAND=( "$SF_ENTRY" run --jsonl --session-create "${runtime_args[@]}" )
  else
    SF_TUI_TRANSPORT_COMMAND=( "$SF_ENTRY" run --jsonl --session "$session" )
  fi
  if (( clear_requested )); then
    zmodload zsh/terminfo && echoti clear || { sf_die 'cannot clear terminal'; return 1; }
  fi
  {
    sf_tui_controller "$session" "$runtime" "$presentation" "$input" \
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
