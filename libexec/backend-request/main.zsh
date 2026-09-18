#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}

source "$SF_ROOT/lib/cli.zsh"

sf_backend_request_abort() {
  sf_process_stop "$SF_BACKEND[pid]" "$SF_BACKEND[group_file]"
  [[ -z $SF_BACKEND[directory] ]] || rm -rf -- "$SF_BACKEND[directory]"
  exit $1
}

sf_backend_request_main() {
  (( ! $# )) || {
    sf_die 'backend-request does not accept arguments'
    return 2
  }
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  source "$SF_ROOT/lib/backend.zsh"
  trap 'sf_backend_request_abort 130' INT
  trap 'sf_backend_request_abort 129' HUP
  trap 'sf_backend_request_abort 143' TERM
  sf_backend_request '[]'
  local request_status=$?
  if (( request_status )); then
    trap - INT HUP TERM
    (( request_status != 129 && request_status != 130 && request_status != 143 )) ||
      return $request_status
    sf_die "$SF_BACKEND[error]"
    return 1
  fi
  trap - INT HUP TERM
  print -r -- "$REPLY"
}

sf_backend_request_main "$@"
typeset exit_status=$?
exit $exit_status
