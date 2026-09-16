emulate -R zsh
setopt no_aliases no_multios pipe_fail

# Where sessions live and how a requested path resolves. Reading or writing a
# session belongs to its owner; this module only names one.

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
