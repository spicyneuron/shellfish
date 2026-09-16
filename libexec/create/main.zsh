#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY="$SF_ROOT/bin/shellfish"
typeset -g SF_CREATE_JSONL=0

source "$SF_ROOT/lib/jq.zsh"

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_create_read_system() {
  local requested=$1 path=$1
  if [[ $path == '~/'* ]]; then
    [[ -n ${HOME-} ]] || { sf_die "cannot expand system file without HOME: $requested"; return 2; }
    path="$HOME/${path#\~/}"
  fi
  [[ $path == /* ]] || path="$PWD/$path"
  [[ -f $path && -r $path ]] || { sf_die "cannot read system file: $requested"; return 2; }
  REPLY=$(<"$path")
}

sf_create_interrupt() {
  local exit_status=$1 session=$2
  if (( exit_status == 130 )); then
    sf_die 'Cancelled.' || true
  else
    sf_die 'Session creation interrupted.' || true
  fi
  [[ -z $session ]] || rm -f -- "$session" 2>/dev/null
  exit $exit_status
}

sf_create_session() {
  local session=$1 runtime=$2 system=$3 error=''
  typeset -gx SHELLFISH_MODE=create
  sf_session_prepare "$runtime" && sf_session_system "$system" || {
    sf_die "$SF_SESSION_ERROR"
    return 1
  }
  printf '%s\n' "${SF_SESSION_RECORDS[@]}" |
    "$SF_ENTRY" install-session --session-out "$session" >/dev/null || return 1
  source "$SF_ROOT/libexec/create/hooks.zsh"
  sf_create_start_hooks "$session" || error=$?
  (( ! error )) || {
    rm -f -- "$session" 2>/dev/null
    sf_session_reset
    return $error
  }
}

sf_create_main() {
  local requested_out='' report runtime session system
  local system_text projection
  local -a forwarded=() system_parts=() system_paths=()
  integer report_status=0 take=0 system_explicit=0
  source "$SF_ROOT/lib/options.zsh"

  while (( $# )); do
    case $1 in
      --jsonl)
        SF_CREATE_JSONL=1
        shift
        ;;
      --session-out)
        [[ -z $requested_out ]] || { sf_die '--session-out may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session-out requires a nonempty path'; return 2; }
        requested_out=$2
        shift 2
        ;;
      --system|--system-file)
        (( $# >= 2 )) || { sf_die "$1 requires a value"; return 2; }
        if [[ $1 == --system-file ]]; then
          [[ -n $2 ]] || { sf_die '--system-file requires a nonempty path'; return 2; }
          sf_create_read_system "$2" || return
          system_text=$REPLY
        else
          system_text=$(print -rn -- "$2")
        fi
        [[ -z $system_text ]] || system_parts+=( "$system_text" )
        system_explicit=1
        shift 2
        ;;
      *)
        # Keep an option with its value when the value resembles an option.
        take=$(( ${SF_CREATE_OPTIONS[$1]:-0} + 1 ))
        (( $# >= take )) || { sf_die "$1 requires a value"; return 2; }
        forwarded+=( "${@:1:$take}" )
        shift $take
        ;;
    esac
  done

  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  report=$("$SF_ENTRY" config "${forwarded[@]}") || report_status=$?
  (( ! report_status )) || return $report_status
  runtime=$(jq -ce 'del(.theme, .tui)' <<<"$report") || {
    sf_die 'cannot resolve the session runtime'
    return 1
  }
  if (( ! system_explicit )); then
    projection=$(jq -jr '.profile.system[] | ., "\u0000"' <<<"$report") ||
      sf_die 'cannot resolve system paths' || return
    system_paths=( ${(@0)projection} )
    for system_text in "${system_paths[@]}"; do
      sf_create_read_system "$system_text" || return
      [[ -z $REPLY ]] || system_parts+=( "$REPLY" )
    done
  fi
  system=${(pj:\n\n:)system_parts}

  source "$SF_ROOT/lib/session/main.zsh"
  source "$SF_ROOT/lib/scratch.zsh"
  trap 'sf_create_interrupt 130 "$session"' INT USR1
  trap 'sf_create_interrupt 129 "$session"' HUP
  trap 'sf_create_interrupt 143 "$session"' TERM
  sf_session_select_path "$requested_out" || {
    sf_die "$SF_SESSION_ERROR"
    return 1
  }
  session=$REPLY
  local create_status=0
  sf_create_session "$session" "$runtime" "$system" || create_status=$?
  if (( create_status )); then
    if (( create_status == 130 )); then
      sf_die 'Cancelled.' || true
    elif (( create_status == 129 || create_status == 143 )); then
      sf_die 'Session creation interrupted.' || true
    fi
    return $create_status
  fi
  if (( SF_CREATE_JSONL )); then
    # Creation ends in the same canonical stream an existing session loads.
    "$SF_ENTRY" load --session "$session" || return 1
  else
    print -r -- "$session" || return 1
  fi
}

sf_create_main "$@"
typeset exit_status=$?
exit $exit_status
