#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY=$SF_ROOT/bin/shellfish
typeset -gr SF_RESUME_ENTRY=${0:A}

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_resume_main() {
  local mode=${1-} session
  local -a tui_args
  integer limit=0 resume_status=0

  case $mode in
    -c|--continue) limit=1 ;;
    -r|--resume) ;;
    *) sf_die "unknown argument: $mode"; return 2 ;;
  esac
  shift
  tui_args=( "$@" )

  if (( ! limit )); then
    if [[ ! -o interactive && -t 1 && ( -t 0 || -r /dev/tty ) ]]; then
      exec zsh -f -i "$SF_RESUME_ENTRY" "$mode" "$@"
    fi
    if [[ ! -o interactive ]]; then
      sf_die 'resume requires an interactive terminal'
      return 2
    fi
    if [[ ! -t 0 ]]; then
      exec </dev/tty || { sf_die 'resume requires an interactive terminal'; return 2; }
    fi
    if [[ ! -t 1 ]]; then sf_die 'resume requires an interactive terminal'; return 2; fi
  fi

  (( $+commands[jq] )) || { sf_die 'shellfish requires jq'; return 2; }
  source "$SF_ROOT/libexec/resume/discovery.zsh"
  sf_session_find $limit || { sf_die "$SF_SESSION_ERROR"; return 1; }
  session=$SF_SESSION_MATCHES[1]

  if (( ! limit )); then
    zmodload zsh/terminfo && echoti clear || { sf_die 'cannot clear terminal'; return 1; }
    source "$SF_ROOT/libexec/resume/picker.zsh"
    sf_resume_run "${SF_SESSION_MATCHES[@]}" || {
      resume_status=$?
      (( resume_status == 130 )) || sf_die "$SF_RESUME_ERROR"
      return $resume_status
    }
    session=$REPLY
    tui_args=( --clear "${tui_args[@]}" )
  fi

  exec -- "$SF_ENTRY" --session "$session" "${tui_args[@]}"
  sf_die 'cannot resume selected session'
}

sf_resume_main "$@"
typeset exit_status=$?
exit $exit_status
