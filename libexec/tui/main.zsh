#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY=$SF_ROOT/bin/shellfish
typeset -gr SF_TUI_ENTRY=${0:A}

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
  local input='' draft='' new_source='' presentation
  local sandbox_detected='{"sandbox_read_paths":[],"sandbox_write_paths":[]}'
  local sandbox_flag sandbox_path resolved_path
  local -a positional=() sandbox_read_paths=() sandbox_write_paths=()
  local -a runtime_args=() presentation_args=()
  local -a original_args=("$@")
  integer session_explicit=0 config_explicit=0 request_explicit=0 runtime_override=0
  integer clear_requested=0 new_requested=0
  integer handoff=0 draft_explicit=0 sandbox_auto_requested=0
  integer verbose_requested=0 controller_status=0

  while (( $# )); do
    case $1 in
      --session)
        (( $# >= 2 )) || { sf_die '--session requires a path'; return 2; }
        (( ! session_explicit )) || {
          sf_die '--session may only be specified once'
          return 2
        }
        [[ -n $2 ]] || { sf_die '--session requires a nonempty path'; return 2; }
        session_explicit=1
        requested_session=$2
        shift 2
        ;;
      --clear)
        clear_requested=1
        shift
        ;;
      --draft)
        (( $# >= 2 )) || { sf_die '--draft requires text'; return 2; }
        (( ! draft_explicit )) || {
          sf_die '--draft may only be specified once'
          return 2
        }
        draft_explicit=1
        draft=$2
        shift 2
        ;;
      --new)
        new_requested=1
        shift
        ;;
      --verbose)
        verbose_requested=1
        presentation_args+=( "$1" )
        shift
        ;;
      --sandbox-auto)
        sandbox_auto_requested=1
        shift
        ;;
      --config)
        (( $# >= 2 )) || { sf_die '--config requires a path'; return 2; }
        (( ! config_explicit )) || {
          sf_die '--config may only be specified once'
          return 2
        }
        [[ -n $2 && $2 != - ]] || {
          sf_die '--config requires a nonempty file path other than -'
          return 2
        }
        config_explicit=1
        runtime_args+=( "$1" "$2" )
        presentation_args+=( "$1" "$2" )
        shift 2
        ;;
      -p|--profile)
        (( $# >= 2 )) || { sf_die "$1 requires a profile name"; return 2; }
        [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
          sf_die '--profile must match [A-Za-z0-9][A-Za-z0-9_-]*'
          return 2
        }
        runtime_override=1
        runtime_args+=( "$1" "$2" )
        shift 2
        ;;
      -m|--model)
        (( $# >= 2 )) || { sf_die "$1 requires a model"; return 2; }
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] || {
          sf_die '--model requires a nonempty value without control characters'
          return 2
        }
        runtime_override=1
        runtime_args+=( "$1" "$2" )
        shift 2
        ;;
      -b|--backend)
        (( $# >= 2 )) || { sf_die "$1 requires a backend name or path"; return 2; }
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] || {
          sf_die '--backend requires a nonempty value without control characters'
          return 2
        }
        runtime_override=1
        runtime_args+=( "$1" "$2" )
        shift 2
        ;;
      --request)
        (( $# >= 2 )) || { sf_die '--request requires a JSON object'; return 2; }
        (( ! request_explicit )) || {
          sf_die '--request may only be specified once'
          return 2
        }
        jq -e 'select(type == "object")' <<<"$2" >/dev/null 2>&1 || {
          sf_die '--request requires a JSON object'
          return 2
        }
        request_explicit=1
        runtime_override=1
        runtime_args+=( "$1" "$2" )
        shift 2
        ;;
      --sandbox-read|--sandbox-write)
        sandbox_flag=$1
        (( $# >= 2 )) || { sf_die "$sandbox_flag requires a path"; return 2; }
        [[ -n $2 ]] || {
          sf_die "$sandbox_flag requires a nonempty path"
          return 2
        }
        sandbox_path=$2
        if [[ $sandbox_path == '~/'* ]]; then
          [[ -n ${HOME-} ]] || {
            sf_die "$sandbox_flag cannot expand ~ without HOME"
            return 2
          }
          sandbox_path="$HOME/${sandbox_path#\~/}"
        elif [[ $sandbox_path != /* ]]; then
          sandbox_path="$PWD/$sandbox_path"
        fi
        resolved_path=${sandbox_path:A}
        [[ -e $resolved_path ]] || {
          sf_die "$sandbox_flag path does not exist: $2"
          return 2
        }
        if [[ $sandbox_flag == --sandbox-read ]]; then
          sandbox_read_paths+=( "$resolved_path" )
        else
          sandbox_write_paths+=( "$resolved_path" )
        fi
        runtime_override=1
        shift 2
        ;;
      --)
        shift
        positional+=( "$@" )
        break
        ;;
      -*)
        sf_die "unknown argument: $1"
        return 2
        ;;
      *)
        positional+=( "$1" )
        shift
        ;;
    esac
  done

  if (( new_requested )); then
    (( ! session_explicit )) || {
      sf_die '--new cannot be combined with --session'
      return 2
    }
    (( ${#positional} <= 1 )) || { sf_die '--new accepts at most one session'; return 2; }
    if (( ${#positional} )); then
      new_source=$positional[1]
      positional=()
      (( ! runtime_override && ! sandbox_auto_requested )) || {
        sf_die 'runtime overrides cannot be used with --new SESSION'
        return 2
      }
    fi
  fi

  if [[ ! -o interactive && -t 1 && ( -t 0 || -r /dev/tty ) ]]; then handoff=1; fi
  (( $+commands[jq] )) || { sf_die 'shellfish requires jq'; return 2; }
  if (( sandbox_auto_requested )); then source "$SF_ROOT/lib/sandbox.zsh"; fi
  if (( sandbox_auto_requested && ! handoff )); then
    sandbox_detected=$(sf_sandbox_detect) || {
      sf_die 'cannot detect sandbox paths'
      return 1
    }
  fi
  typeset -gx _SHELLFISH_SANDBOX_READ_PATHS _SHELLFISH_SANDBOX_WRITE_PATHS
  _SHELLFISH_SANDBOX_READ_PATHS=$(jq -cn --argjson detected "$sandbox_detected" \
    '$ARGS.positional + $detected.sandbox_read_paths' --args -- \
    "${sandbox_read_paths[@]}") || return 1
  _SHELLFISH_SANDBOX_WRITE_PATHS=$(jq -cn --argjson detected "$sandbox_detected" \
    '$ARGS.positional + $detected.sandbox_write_paths' --args -- \
    "${sandbox_write_paths[@]}") || return 1
  typeset -gx SHELLFISH_VERBOSE=$verbose_requested
  (( ! sandbox_auto_requested )) || runtime_override=1

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

  source "$SF_ROOT/lib/session/startup.zsh"
  integer startup_status=0 config_status=0
  sf_session_open "$requested_session" "$runtime_override" \
    "$new_source" "${runtime_args[@]}" || startup_status=$?
  if (( startup_status )); then
    [[ -z $SF_SESSION_STARTUP_ERROR ]] || sf_die "$SF_SESSION_STARTUP_ERROR"
    return $startup_status
  fi
  presentation=$("$SF_ENTRY" config --session "$SF_SESSION_OPEN[path]" \
    "${presentation_args[@]}") || config_status=$?
  (( ! config_status )) || return $config_status

  source "$SF_ROOT/libexec/tui/render/main.zsh"
  source "$SF_ROOT/libexec/tui/transport.zsh"
  source "$SF_ROOT/libexec/tui/editor.zsh"
  source "$SF_ROOT/libexec/tui/controller.zsh"
  SF_TUI_TRANSPORT_COMMAND=( "$SF_ENTRY" run --jsonl --session "$SF_SESSION_OPEN[path]" )
  if (( clear_requested )); then
    zmodload zsh/terminfo && echoti clear || { sf_die 'cannot clear terminal'; return 1; }
  fi
  sf_tui_controller "$SF_SESSION_OPEN[path]" "$presentation" "$input" \
    "$SF_SESSION_OPEN[mode]" "$draft" || controller_status=$?
  if (( controller_status )); then
    [[ -z $SF_PRESENT_ERROR ]] || sf_die "$SF_PRESENT_ERROR"
    return $controller_status
  fi
}

sf_tui_main "$@"
typeset exit_status=$?
exit $exit_status
