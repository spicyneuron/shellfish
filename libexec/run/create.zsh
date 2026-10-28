emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/profile.zsh"
source "$SF_ROOT/lib/session.zsh"

sf_run_create() {
  local requested_out='' source_session='' profile session header cwd created
  local -a forwarded=()
  integer resolve_status=0 take=0

  while (( $# )); do
    case $1 in
      --session-out)
        [[ -z $requested_out ]] || { sf_die '--session-out may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session-out requires a nonempty path'; return 2; }
        requested_out=$2
        shift 2
        ;;
      --session-from)
        [[ -z $source_session ]] || { sf_die '--session-from may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session-from requires a nonempty path'; return 2; }
        source_session=$2
        shift 2
        ;;
      *)
        take=$(( ${SF_CREATE_OPTIONS[$1]:-0} + 1 ))
        (( $# >= take )) || { sf_die "$1 requires a value"; return 2; }
        forwarded+=( "${@:1:$take}" )
        shift $take
        ;;
    esac
  done

  sf_run_limits || { sf_die "$REPLY"; return 1; }
  if [[ -n $source_session ]]; then
    (( ! ${#forwarded} )) || {
      sf_die 'profile overrides cannot be used with --session-from'
      return 2
    }
    sf_session_select_path "$source_session" || { sf_die "$SF_SESSION_ERROR"; return 1; }
    sf_session_read_profile "$REPLY" || { sf_die "$SF_SESSION_ERROR"; return 1; }
    profile=$REPLY
  else
    sf_profile_resolve_args "${forwarded[@]}" || {
      resolve_status=$?
      sf_die "$SF_PROFILE_ERROR"
      return $resolve_status
    }
    profile=$REPLY
  fi
  sf_run_components "$profile" || { sf_die "$REPLY"; return 1; }
  sf_session_select_path "$requested_out" || { sf_die "$SF_SESSION_ERROR"; return 1; }
  session=$REPLY
  cwd=$(pwd -P) && created=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
    sf_die 'cannot prepare session header'
    return 1
  }
  header=$(sf_jq -cn --arg cwd "$cwd" --arg created "$created" --arg share "$SF_SHARE" \
    --arg home "${HOME:+${HOME:A}}" --argjson profile "$profile" '
    include "lib/profile";
    {type:"session",format_version:1,cwd:($cwd | store_path(""; $home)),created:$created,
     profile:($profile | profile_store($share; $home))} | select(canonical_session_header)
  ') || { sf_die 'cannot prepare session header'; return 1; }
  (
    umask 077
    setopt no_clobber
    print -r -- "$header" >"$session"
  ) 2>/dev/null || {
    [[ ! -e $session && ! -L $session ]] || sf_die "session already exists: $session" || return 1
    sf_die "cannot create session: $session"
    return 1
  }

  SF_RUN[profile]=$profile
  SF_RUN[cwd]=$cwd
  SF_RUN[turn_id]=1
  SF_RUN[hook_id]=1
  if (( SF_RUN[jsonl] )); then
    sf_run_emit "$(jq -cn --arg path "$session" '{type:"_session_load",path:$path}')" || return 1
    sf_run_emit "$header" || return 1
  fi
  sf_run_hooks "$session" session_start '' '' || {
    (( ! SF_RUN[signal_status] )) || return $SF_RUN[signal_status]
    sf_die "$SF_RUN_HOOK_ERROR"
    return 1
  }
  REPLY=$session
}
