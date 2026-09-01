emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_prepare] )) || source "$SF_ROOT/lib/session/main.zsh"
(( $+functions[sf_hooks_session_start] )) || source "$SF_ROOT/lib/hooks.zsh"

typeset -g SF_SESSION_STARTUP_ERROR=''

sf_session_startup_create() {
  local session=$1 runtime=$2
  SF_SESSION_STARTUP_ERROR=''
  SF_SESSION_PATH=$session
  SHELLFISH_SESSION_STATE=''
  if ! sf_hooks_session_state_create; then
    SF_SESSION_STARTUP_ERROR=$SF_HOOK_ERROR
  elif ! sf_session_prepare "$runtime"; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  elif ! sf_hooks_system "$session"; then
    SF_SESSION_STARTUP_ERROR=$SF_HOOK_ERROR
  elif ! sf_hooks_session_start "$session"; then
    SF_SESSION_STARTUP_ERROR=$SF_HOOK_ERROR
  elif ! sf_session_create "${SF_HOOK_CONTEXT_RECORDS[@]}"; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  fi
  [[ -z $SF_SESSION_STARTUP_ERROR ]]
}
