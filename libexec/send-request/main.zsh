#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

# Usable only after lib/request.zsh defines sf_process_stop and SF_REQUEST.
sf_send_request_abort() {
  sf_process_stop "$SF_REQUEST[pid]"
  [[ -z $SF_REQUEST[error_file] ]] || rm -f -- "$SF_REQUEST[error_file]"
  exit $1
}

sf_send_request_main() {
  local requested_session='' selected request runtime backend_command
  local api_key api_key_source
  integer session_explicit=0

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
      --)
        shift
        (( ! $# )) || {
          sf_die 'send-request does not accept a prompt'
          return 2
        }
        ;;
      -*)
        sf_die 'send-request only supports --session'
        return 2
        ;;
      *)
        sf_die 'send-request does not accept a prompt'
        return 2
        ;;
    esac
  done

  (( session_explicit )) || {
    sf_die 'send-request requires --session'
    return 2
  }
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  source "$SF_ROOT/lib/runtime/main.zsh"
  source "$SF_ROOT/lib/session/main.zsh"
  source "$SF_ROOT/lib/request.zsh"
  sf_session_select_path "$requested_session" || {
    sf_die "$SF_SESSION_ERROR"
    return 1
  }
  selected=$REPLY
  [[ -f $selected && ! -L $selected && -r $selected ]] || {
    sf_die "invalid session path: $selected"
    return 1
  }
  sf_session_read_runtime "$selected" || {
    sf_die "$SF_SESSION_ERROR"
    return 1
  }
  runtime=$REPLY
  request=$(cat)
  [[ -n $request ]] || {
    sf_die 'send-request requires a canonical backend request on stdin'
    return 2
  }
  request=$(jq -L "$SF_ROOT" -cse --argjson runtime "$runtime" '
    include "lib/runtime/schema";
    select(length == 1) | .[0] |
    select(canonical_request) |
    select(.options == {request:$runtime.profile.request}) |
    select(.transport == ($runtime.backend |
      {endpoint,insecure_tls,http_timeout,http_stall}))
  ' <<<"$request" 2>/dev/null) || {
    sf_die 'send-request requires a canonical request for the selected session'
    return 2
  }
  backend_command=$(jq -er '.backend.command' <<<"$runtime") || {
    sf_die 'cannot inspect frozen runtime'
    return 1
  }
  sf_runtime_resolve_api_key "$runtime" || {
    sf_die "$SF_RUNTIME_ERROR"
    return 1
  }
  api_key=$REPLY
  api_key_source=$reply[1]
  trap 'sf_send_request_abort 130' INT
  trap 'sf_send_request_abort 129' HUP
  trap 'sf_send_request_abort 143' TERM
  sf_request_run "$request" "$backend_command" "$api_key" "$api_key_source" || {
    trap - INT HUP TERM
    sf_die "$SF_REQUEST[error]"
    return 1
  }
  trap - INT HUP TERM
  print -r -- "$SF_REQUEST[assistant]"
}

sf_send_request_main "$@"
typeset exit_status=$?
exit $exit_status
