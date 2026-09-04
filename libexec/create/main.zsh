#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY="$SF_ROOT/bin/shellfish"

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_create_main() {
  local requested_path='' report runtime session
  local -a forwarded=()
  integer path_explicit=0 report_status=0

  while (( $# )); do
    case $1 in
      --path)
        (( $# >= 2 )) || {
          sf_die '--path requires a path'
          return 2
        }
        (( ! path_explicit )) || {
          sf_die '--path may only be specified once'
          return 2
        }
        [[ -n $2 ]] || {
          sf_die '--path requires a nonempty path'
          return 2
        }
        path_explicit=1
        requested_path=$2
        shift 2
        ;;
      *)
        forwarded+=( "$1" )
        shift
        ;;
    esac
  done

  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  # Configuration resolution belongs to shellfish config, including its rejection
  # of runtime overrides against an existing --session.
  report=$("$SF_ENTRY" config "${forwarded[@]}") || report_status=$?
  (( ! report_status )) || return $report_status
  runtime=$(jq -ce 'del(.theme, .tui)' <<<"$report") || {
    sf_die 'cannot resolve the session runtime'
    return 1
  }

  source "$SF_ROOT/lib/session/startup.zsh"
  sf_session_select_path "$requested_path" || {
    sf_die "$SF_SESSION_ERROR"
    return 1
  }
  session=$REPLY
  [[ ! -s $session ]] || {
    sf_die "session already exists: $session"
    return 1
  }
  [[ ! -e $session || ( -f $session && ! -L $session ) ]] || {
    sf_die "invalid session path: $session"
    return 1
  }
  sf_session_startup_create "$session" "$runtime" || {
    sf_die "$SF_SESSION_STARTUP_ERROR"
    return 1
  }
  print -r -- "$session"
}

sf_create_main "$@"
typeset exit_status=$?
exit $exit_status
