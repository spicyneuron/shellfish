#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_SHARE=$SF_ROOT/share
typeset -gr SF_ENTRY=$SF_ROOT/bin/shellfish

source "$SF_ROOT/lib/session.zsh"
source "$SF_ROOT/lib/profile.zsh"

sf_complete_main() {
  if (( $# != 3 )) || [[ $1 != --session || -z $2 || -z $3 ]]; then
    sf_die 'usage: shellfish complete --session PATH TOKEN'
    return 2
  fi
  local session token=$3 script
  local -A fields
  sf_session_select_path "$2" || { sf_die "$SF_ERROR"; return 1; }
  session=$REPLY
  sf_session_read_header "$session" || { sf_die "$SF_ERROR"; return 1; }
  sf_jq_fields '
    include "lib/fields";
    entry("catalog"; {hooks:.profile.hooks,commands:[],tools:[]} | tojson),
    entry("config"; .profile.config // {} | tojson),
    entry("model"; .model.request.model), entry("cwd"; .cwd), ("ok" | field)
  ' <<<"$REPLY" || { sf_die "cannot read completion context: $session"; return 1; }
  fields=( "${reply[@]}" )
  sf_profile_components "$fields[catalog]" || { sf_die "$SF_ERROR"; return 1; }
  script=$(jq -r --arg prefix "${token[1]}" '
    first(.hooks[] | select(.manifest.complete == $prefix) |
      .command | rtrimstr("/run") + "/complete")
  ' <<<"$REPLY") || return 1
  [[ -n $script ]] || return 0
  [[ -f $script && -x $script ]] || { sf_die "hook completer is not executable: $script"; return 1; }
  local SHELLFISH_MODE=run
  [[ ${SHELLFISH_VERBOSE-} == 1 ]] || local SHELLFISH_VERBOSE=0
  sf_environment_hook "$session" "$fields[config]" "$fields[model]" ||
    { sf_die "$SF_ERROR"; return 1; }
  builtin cd -q -- "$fields[cwd]" 2>/dev/null ||
    { sf_die "session working directory is unavailable: $fields[cwd]"; return 1; }
  exec /usr/bin/env -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE \
    "${reply[@]}" "$script" "$token" </dev/null 3>&-
}

sf_complete_main "$@"
