emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Where sessions live, how one is named, and the two durable mutations.

typeset -g SF_SESSION_ERROR=''

sf_session_fail() {
  SF_SESSION_ERROR=$1
  return 1
}

sf_session_directory() {
  local LC_ALL=C root cwd scope
  setopt local_options extended_glob
  if [[ -n ${XDG_STATE_HOME-} ]]; then
    root="$XDG_STATE_HOME/shellfish/sessions"
  elif [[ -n ${HOME-} ]]; then
    root="$HOME/.local/state/shellfish/sessions"
  else
    sf_session_fail 'HOME or XDG_STATE_HOME is required when --session is omitted'
    return
  fi
  cwd=$(pwd -P) || {
    sf_session_fail 'cannot resolve the working directory'
    return
  }
  scope=${cwd//[^A-Za-z0-9]##/_}
  REPLY="$root/$scope"
}

# An empty request names a new session in the current project's directory.
sf_session_select_path() {
  local requested=${1-} directory created
  SF_SESSION_ERROR=''
  if [[ -n $requested ]]; then
    [[ $requested == /* ]] || requested="$PWD/$requested"
    REPLY=${requested:a}
    return
  fi

  sf_session_directory || return
  directory=$REPLY
  mkdir -p "$directory" && chmod 700 "$directory" || {
    sf_session_fail "cannot prepare session directory: $directory"
    return
  }
  created=$(date -u '+%Y%m%dT%H%M%SZ') || {
    sf_session_fail 'cannot timestamp session'
    return
  }
  REPLY="$directory/$created-${sysparams[pid]}-$RANDOM$RANDOM.jsonl"
}

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

# The session's profile with absolute paths.
sf_session_read_profile() {
  local session_path=$1 header
  [[ -f $session_path && ! -L $session_path && -r $session_path ]] || {
    sf_session_fail "invalid session path: $session_path"
    return
  }
  IFS= read -r header <"$session_path" || {
    sf_session_fail "cannot read session header: $session_path"
    return
  }
  REPLY=$(sf_jq -cnce --argjson header "$header" --arg share "$SF_SHARE" \
      --arg home "${HOME:+${HOME:A}}" '
    include "lib/profile";
    $header | select(canonical_session_header) | header_expand($share; $home) | .profile
  ' 2>/dev/null) || {
    sf_session_fail "cannot read session header: $session_path"
    return
  }
}

sf_session_append() {
  local session_path=$1 record=$2
  SF_SESSION_ERROR=''
  if ! print -r -- "$record" >>"$session_path"; then
    sf_session_fail "cannot append session record: $session_path"
    return
  fi
}

sf_session_replace_profile() {
  local session_path=$1 profile=$2 temp error=''
  SF_SESSION_ERROR=''
  temp=$(mktemp "${session_path:h}/.${session_path:t}.XXXXXX") || {
    sf_session_fail "cannot prepare session update: $session_path"
    return
  }
  chmod 600 "$temp" || error="cannot secure session update: $session_path"
  if [[ -z $error ]]; then
    sf_jq -cs --argjson profile "$profile" --arg share "$SF_SHARE" \
        --arg home "${HOME:+${HOME:A}}" '
      include "lib/profile";
      .[0].profile = ($profile | profile_store($share; $home)) |
      if .[0] | canonical_session_header then .[] else error("invalid profile") end
    ' "$session_path" >"$temp" 2>/dev/null || error='invalid session profile replacement'
  fi
  [[ -n $error ]] || mv -f -- "$temp" "$session_path" ||
    error="cannot replace session: $session_path"
  if [[ -n $error ]]; then
    rm -f -- "$temp" 2>/dev/null
    sf_session_fail "$error"
    return 1
  fi
}
