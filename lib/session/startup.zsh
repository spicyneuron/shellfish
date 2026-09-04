emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_prepare] )) || source "$SF_ROOT/lib/session/main.zsh"
(( $+functions[sf_hooks_session_start] )) || source "$SF_ROOT/lib/hooks.zsh"
(( $+functions[sf_runtime_resolve] )) || source "$SF_ROOT/lib/runtime/main.zsh"

typeset -g SF_SESSION_STARTUP_ERROR=''
typeset -gA SF_SESSION_OPEN=( path '' presentation '' mode '' )

# Resolves what a client needs to attach to a session: its path, the current
# presentation, and whether the transcript already existed or was created here.
# Creation belongs to shellfish create, which reports its own failures.
# The frozen runtime stays in the transcript; clients read it from there.
sf_session_open() {
  local requested=$1 config=$2
  integer override=$3 continue_requested=$4
  local source_session=$5 created
  shift 5
  local -a create=( "$SF_ENTRY" create )

  SF_SESSION_STARTUP_ERROR=''
  SF_SESSION_OPEN=( path '' presentation '' mode resume )

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
      SF_SESSION_STARTUP_ERROR='runtime overrides cannot be used with an existing session'
      return 2
    }
  else
    SF_SESSION_OPEN[mode]=startup
    created=$("${create[@]}" "$@") || return 1
    [[ -n $created ]] || {
      SF_SESSION_STARTUP_ERROR='create did not return a session path'
      return 1
    }
    SF_SESSION_OPEN[path]=$created
  fi

  sf_runtime_restore_presentation "$config" || {
    SF_SESSION_STARTUP_ERROR=$SF_RUNTIME_ERROR
    return 1
  }
  SF_SESSION_OPEN[presentation]=$SF_PRESENTATION
}

sf_session_startup_create() {
  local session=$1 runtime=$2
  SF_SESSION_STARTUP_ERROR=''
  SF_SESSION_PATH=$session
  SHELLFISH_SESSION_STATE=''
  if ! sf_hooks_session_state_create; then
    SF_SESSION_STARTUP_ERROR=$SF_HOOK_ERROR
  elif ! sf_session_prepare "$runtime"; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  elif ! sf_session_system; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  elif ! sf_hooks_session_start "$session"; then
    SF_SESSION_STARTUP_ERROR=$SF_HOOK_ERROR
  elif ! sf_session_create "${SF_HOOK_CONTEXT_RECORDS[@]}"; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  fi
  [[ -z $SF_SESSION_STARTUP_ERROR ]]
}
