emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/runtime.zsh"
source "$SF_ROOT/lib/session.zsh"

sf_run_read_system() {
  local requested=$1 path=$1
  if [[ $path == '~/'* ]]; then
    [[ -n ${HOME-} ]] || { sf_die "cannot expand system file without HOME: $requested"; return 2; }
    path="$HOME/${path#\~/}"
  fi
  [[ $path == /* ]] || path="$PWD/$path"
  [[ -f $path && -r $path ]] || { sf_die "cannot read system file: $requested"; return 2; }
  REPLY=$(<"$path")
  [[ $REPLY != *$'\0'* ]] || {
    sf_die "system file contains NUL bytes: $requested"
    return 2
  }
}

sf_run_create() {
  local requested_out='' source_session='' runtime session system system_text projection header record cwd created
  local -a forwarded=() system_parts=() system_paths=()
  integer resolve_status=0 take=0 system_explicit=0 runtime_override=0

  while (( $# )); do
    case $1 in
      --session-out)
        [[ -z $requested_out ]] || { sf_die '--session-out may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session-out requires a nonempty path'; return 2; }
        requested_out=$2
        shift 2
        ;;
      --system|--system-file)
        (( $# >= 2 )) || { sf_die "$1 requires a value"; return 2; }
        if [[ $1 == --system-file ]]; then
          [[ -n $2 ]] || { sf_die '--system-file requires a nonempty path'; return 2; }
          sf_run_read_system "$2" || return
          system_text=$REPLY
        else
          system_text=$(print -rn -- "$2")
        fi
        [[ -z $system_text ]] || system_parts+=( "$system_text" )
        system_explicit=1
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
        [[ $1 == --config ]] || runtime_override=1
        shift $take
        ;;
    esac
  done

  if [[ -n $source_session ]]; then
    (( ! runtime_override )) || {
      sf_die 'runtime overrides cannot be used with --session-from'
      return 2
    }
    sf_session_select_path "$source_session" || { sf_die "$SF_SESSION_ERROR"; return 1; }
    sf_session_read_runtime "$REPLY" || { sf_die "$SF_SESSION_ERROR"; return 1; }
    runtime=$REPLY
  else
    sf_runtime_resolve_args "${forwarded[@]}" || {
      resolve_status=$?
      sf_die "$SF_RUNTIME_ERROR"
      return $resolve_status
    }
    runtime=$REPLY
  fi
  if (( ! system_explicit )); then
    projection=$(jq -jr '.profile.system[] | ., "\u0000"' <<<"$runtime") ||
      sf_die 'cannot resolve system paths' || return
    system_paths=( ${(@0)projection} )
    for system_text in "${system_paths[@]}"; do
      sf_run_read_system "$system_text" || return
      [[ -z $REPLY ]] || system_parts+=( "$REPLY" )
    done
  fi
  system=${(pj:\n\n:)system_parts}

  sf_session_select_path "$requested_out" || { sf_die "$SF_SESSION_ERROR"; return 1; }
  session=$REPLY
  cwd=$(pwd -P) && created=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
    sf_die 'cannot prepare session header'
    return 1
  }
  header=$(sf_jq -cn --arg cwd "$cwd" --arg created "$created" \
    --arg home "${HOME:A}" --argjson runtime "$runtime" '
    include "lib/runtime";
    {type:"session",format_version:1,cwd:$cwd,created:$created,runtime:$runtime} |
    header_store($home) | select(canonical_session_header)
  ') || { sf_die 'cannot prepare session header'; return 1; }
  local -a records=( "$header" )
  if [[ -n $system ]]; then
    record=$(jq -cn --arg content "$system" '{type:"system",content:$content}') || {
      sf_die 'cannot prepare system record'
      return 1
    }
    records+=( "$record" )
  fi
  (
    umask 077
    setopt no_clobber
    printf '%s\n' "${records[@]}" >"$session"
  ) 2>/dev/null || {
    [[ ! -e $session && ! -L $session ]] || sf_die "session already exists: $session" || return 1
    sf_die "cannot create session: $session"
    return 1
  }

  SF_RUN[runtime]=$runtime
  SF_RUN[cwd]=$cwd
  SF_RUN[turn_id]=1
  SF_RUN[hook_id]=1
  if (( SF_RUN[jsonl] )); then
    sf_run_emit "$(jq -cn --arg path "$session" '{type:"_session_load",path:$path}')" || return 1
    for record in "${records[@]}"; do
      sf_run_emit "$record" || return 1
    done
  fi
  sf_run_hooks "$session" session_start '' '' || {
    (( ! SF_RUN[signal_status] )) || return $SF_RUN[signal_status]
    sf_die "$SF_RUN_HOOK_ERROR"
    return 1
  }
  REPLY=$session
}
