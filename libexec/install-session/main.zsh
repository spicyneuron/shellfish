#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -g SF_INSTALL_DESTINATION=''
typeset -g SF_INSTALL_TEMP=''

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_install_cleanup() {
  [[ -z $SF_INSTALL_TEMP ]] || rm -f -- "$SF_INSTALL_TEMP" 2>/dev/null
}

sf_install_main() {
  local requested_out=''
  integer out_explicit=0

  while (( $# )); do
    case $1 in
      --session-out)
        (( ! out_explicit )) || {
          sf_die '--session-out may only be specified once'
          return 2
        }
        [[ -n $2 ]] || {
          sf_die '--session-out requires a nonempty path'
          return 2
        }
        requested_out=$2
        out_explicit=1
        shift 2
        ;;
      --)
        shift
        (( ! $# )) || {
          sf_die 'install-session does not accept arguments'
          return 2
        }
        ;;
      *)
        sf_die 'install-session only supports --session-out'
        return 2
        ;;
    esac
  done

  (( out_explicit )) || {
    sf_die 'install-session requires --session-out'
    return 2
  }
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  [[ $requested_out == /* ]] || requested_out="$PWD/$requested_out"
  SF_INSTALL_DESTINATION=${requested_out:a}
  [[ ! -e $SF_INSTALL_DESTINATION && ! -L $SF_INSTALL_DESTINATION ]] || {
    sf_die "session already exists: $SF_INSTALL_DESTINATION"
    return 1
  }

  SF_INSTALL_TEMP=$(mktemp \
    "$SF_INSTALL_DESTINATION:h/.${SF_INSTALL_DESTINATION:t}.XXXXXX") || {
    sf_die "cannot prepare session installation: $SF_INSTALL_DESTINATION"
    return 1
  }
  chmod 600 "$SF_INSTALL_TEMP" || {
    sf_die "cannot secure session installation: $SF_INSTALL_DESTINATION"
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
    ($records[1:] | session_records_state) as $state |
    select($state.valid and $state.next == "user" and
      ($state.pending | length) == 0)
  ' "$SF_INSTALL_TEMP" >/dev/null 2>&1 || {
    sf_die 'install-session requires one complete canonical JSONL transcript on stdin'
    return 2
  }

  ln -- "$SF_INSTALL_TEMP" "$SF_INSTALL_DESTINATION" 2>/dev/null || {
    if [[ -e $SF_INSTALL_DESTINATION || -L $SF_INSTALL_DESTINATION ]]; then
      sf_die "session already exists: $SF_INSTALL_DESTINATION"
    else
      sf_die "cannot install session: $SF_INSTALL_DESTINATION"
    fi
    return 1
  }
  print -r -- "$SF_INSTALL_DESTINATION" || return 1
}

trap sf_install_cleanup EXIT
sf_install_main "$@"
typeset exit_status=$?
exit $exit_status
