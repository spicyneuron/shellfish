emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_find] )) || source "$SF_ROOT/lib/session/main.zsh"

typeset -g SF_SESSION_STARTUP_ERROR=''
typeset -gA SF_SESSION_OPEN=( path '' mode '' )

# Resolves which session a client attaches to and whether that transcript
# already existed or was created here. Creation belongs to shellfish create,
# which reports its own failures. The frozen runtime stays in the transcript.
sf_session_open() {
  local requested=$1
  integer override=$2 continue_requested=$3
  local source_session=$4 created
  shift 4
  local -a create=( "$SF_ENTRY" create )

  SF_SESSION_STARTUP_ERROR=''
  SF_SESSION_OPEN=( path '' mode resume )

  if (( continue_requested )); then
    sf_session_find 1 || {
      SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
      return 1
    }
    requested=$SF_SESSION_MATCHES[1]
  fi
  if [[ -n $requested ]]; then
    sf_session_select_path "$requested" || {
      SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
      return 1
    }
    SF_SESSION_OPEN[path]=$REPLY
    create+=( --path "$REPLY" )
  fi
  [[ -z $source_session ]] || create+=( --session "$source_session" )

  if [[ -n $SF_SESSION_OPEN[path] && -s $SF_SESSION_OPEN[path] ]]; then
    (( ! override )) || {
      SF_SESSION_STARTUP_ERROR='options that configure a new session cannot be used with an existing one'
      return 2
    }
  else
    SF_SESSION_OPEN[mode]=startup
    local create_status=0
    created=$("${create[@]}" "$@") || create_status=$?
    (( ! create_status )) || return $create_status
    [[ -n $created ]] || {
      SF_SESSION_STARTUP_ERROR='create did not return a session path'
      return 1
    }
    SF_SESSION_OPEN[path]=$created
  fi
}
