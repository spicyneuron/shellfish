#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_build_request_main() {
  local requested_session='' requested_tools='[]' selected record
  integer session_explicit=0 tools_explicit=0

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
      --tools)
        (( $# >= 2 )) || {
          sf_die '--tools requires a JSON array'
          return 2
        }
        (( ! tools_explicit )) || {
          sf_die '--tools may only be specified once'
          return 2
        }
        requested_tools=$(jq -ce 'select(type == "array")' <<<"$2" 2>/dev/null) || {
          sf_die '--tools requires a JSON array'
          return 2
        }
        tools_explicit=1
        shift 2
        ;;
      --)
        shift
        (( ! $# )) || {
          sf_die 'build-request does not accept a prompt'
          return 2
        }
        ;;
      -*)
        sf_die 'build-request only supports --session and --tools'
        return 2
        ;;
      *)
        sf_die 'build-request does not accept a prompt'
        return 2
        ;;
    esac
  done

  (( session_explicit )) || {
    sf_die 'build-request requires --session'
    return 2
  }
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

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
  SF_SESSION_PATH=$selected
  sf_session_read || {
    sf_die "$SF_SESSION_ERROR"
    return 1
  }
  while IFS= read -r record; do
    [[ -n $record ]] || {
      sf_die 'build-request requires nonempty JSONL records'
      return 2
    }
    SF_SESSION_RECORDS+=( "$record" )
  done
  sf_session_project || {
    sf_die 'build-request received invalid session records'
    return 2
  }
  printf '%s\n' "${SF_SESSION_RECORDS[@]}" |
    sf_request_build "$SF_SESSION[runtime]" "$requested_tools" || {
      sf_die 'cannot build backend request'
      return 1
    }
}

sf_build_request_main "$@"
typeset exit_status=$?
exit $exit_status
