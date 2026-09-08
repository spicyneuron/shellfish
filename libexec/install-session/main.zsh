#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -g SF_INSTALL_TEMP=''

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_install_cleanup() {
  [[ -z $SF_INSTALL_TEMP ]] || rm -f -- "$SF_INSTALL_TEMP" 2>/dev/null
}

sf_install_main() {
  (( $# == 2 )) && [[ $1 == --session-out && -n $2 ]] || {
    sf_die 'install-session accepts only --session-out PATH'
    return 2
  }
  local requested_out=$2 destination
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  [[ $requested_out == /* ]] || requested_out="$PWD/$requested_out"
  destination=${requested_out:a}
  # Callers name their own children, so an occupied destination reports status 3
  # and lets them choose another name.
  [[ ! -e $destination && ! -L $destination ]] || {
    sf_die "session already exists: $destination"
    return 3
  }

  SF_INSTALL_TEMP=$(mktemp "$destination:h/.${destination:t}.XXXXXX") || {
    sf_die "cannot prepare session installation: $destination"
    return 1
  }
  chmod 600 "$SF_INSTALL_TEMP" || {
    sf_die "cannot secure session installation: $destination"
    return 1
  }
  cat >"$SF_INSTALL_TEMP" || {
    sf_die "cannot read session transcript"
    return 1
  }

  source "$SF_ROOT/lib/jq.zsh"
  sf_jq -Rse '
    include "lib/runtime/schema";
    select(endswith("\n")) |
    split("\n") as $lines |
    select($lines[-1] == "" and ($lines[0:-1] | length > 0) and
      all($lines[0:-1][]; length > 0)) |
    ($lines[0:-1] | map(fromjson)) as $records |
    select($records[0] | canonical_session_header(1)) |
    select($records[1:] | session_records_state | .valid)
  ' "$SF_INSTALL_TEMP" >/dev/null 2>&1 || {
    sf_die 'install-session requires one canonical JSONL transcript on stdin'
    return 2
  }

  ln -- "$SF_INSTALL_TEMP" "$destination" 2>/dev/null || {
    [[ ! -e $destination && ! -L $destination ]] || {
      sf_die "session already exists: $destination"
      return 3
    }
    sf_die "cannot install session: $destination"
    return 1
  }
  print -r -- "$destination" || return 1
}

trap sf_install_cleanup EXIT
sf_install_main "$@"
typeset exit_status=$?
exit $exit_status
