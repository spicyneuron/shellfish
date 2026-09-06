emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_select_path] )) || source "$SF_ROOT/lib/session/main.zsh"

typeset -g SF_SESSION_STARTUP_ERROR=''
typeset -gA SF_SESSION_OPEN=( path '' mode '' )

# Resolves which session a client attaches to. A requested session must already
# exist; otherwise one is created from the remaining options. Creation belongs
# to shellfish create, which reports its own failures and prints the path it
# chose. The frozen runtime stays in the transcript.
sf_session_open() {
  local requested=$1
  integer override=$2
  shift 2

  SF_SESSION_STARTUP_ERROR=''
  SF_SESSION_OPEN=( path '' mode resume )

  if [[ -n $requested ]]; then
    sf_session_select_path "$requested" || {
      SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
      return 1
    }
    [[ -s $REPLY ]] || {
      SF_SESSION_STARTUP_ERROR="no session at $REPLY; use --session-out to create one"
      return 1
    }
    (( ! override )) || {
      SF_SESSION_STARTUP_ERROR='options that configure a new session cannot be used with an existing one'
      return 2
    }
    SF_SESSION_OPEN[path]=$REPLY
    return 0
  fi

  SF_SESSION_OPEN[mode]=startup
  local created create_status=0
  created=$("$SF_ENTRY" create "$@") || create_status=$?
  (( ! create_status )) || return $create_status
  [[ -n $created ]] || {
    SF_SESSION_STARTUP_ERROR='create did not return a session path'
    return 1
  }
  SF_SESSION_OPEN[path]=$created
}
