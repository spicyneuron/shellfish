#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

# Read-only canonical session boundary: validate, then emit the path event, the
# header, and the durable records in file order.
sf_load_main() {
  local requested='' session
  integer session_explicit=0

  while (( $# )); do
    case $1 in
      -s|--session)
        (( ! session_explicit )) || { sf_die '--session may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session requires a nonempty path'; return 2; }
        session_explicit=1
        requested=$2
        shift 2
        ;;
      *) sf_die "unknown argument: $1"; return 2 ;;
    esac
  done
  (( session_explicit )) || { sf_die 'load requires --session'; return 2; }
  (( $+commands[jq] )) || { sf_die 'shellfish requires jq'; return 2; }

  source "$SF_ROOT/lib/jq.zsh"
  source "$SF_ROOT/lib/session.zsh"
  sf_session_select_path "$requested" || { sf_die "$SF_SESSION_ERROR"; return 1; }
  session=$REPLY
  [[ -f $session && ! -L $session && -r $session ]] ||
    { sf_die "invalid session path: $session"; return 1; }
  sf_jq -jRs --arg path "$session" -f "$SF_ROOT/libexec/load/load.jq" <"$session" ||
    { sf_die "cannot read session: $session"; return 1; }
}

sf_load_main "$@"
typeset exit_status=$?
exit $exit_status
