emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_scratch_category] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_HOOK_ERROR=''
typeset -g SHELLFISH_TURN_STATE=${SHELLFISH_TURN_STATE-}
typeset -g SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
typeset -g SF_HOOK_TURN_STATE_TEMP=''

zshexit() {
  [[ -z $SF_HOOK_TURN_STATE_TEMP ]] || rm -rf -- "$SF_HOOK_TURN_STATE_TEMP" 2>/dev/null || true
}

sf_hooks_reset() {
  SF_HOOK_ERROR=''
  REPLY=''
  reply=()
}

sf_hooks_fail() {
  local error=$1
  sf_hooks_reset
  SF_HOOK_ERROR=$error
  return 1
}

sf_hooks_turn_state_create() {
  [[ -z $SHELLFISH_TURN_STATE ]] || return 0
  sf_scratch_create turns turn || {
    sf_hooks_fail 'cannot prepare hook turn state'
    return
  }
  SHELLFISH_TURN_STATE=$REPLY
  SF_HOOK_TURN_STATE_TEMP=$SHELLFISH_TURN_STATE
}

sf_hooks_turn_state_cleanup() {
  [[ -z $SF_HOOK_TURN_STATE_TEMP ]] ||
    rm -rf -- "$SF_HOOK_TURN_STATE_TEMP" 2>/dev/null || true
  SF_HOOK_TURN_STATE_TEMP=''
  unset SHELLFISH_TURN_STATE
}

sf_hooks_run() {
  local hook=$2 label=$2
  [[ $hook != pre_tool_use ]] || label=pre-tool

  SF_HOOK_ERROR=''
  (( ${+SF_HOOK_COUNTS[$hook]} )) || {
    sf_hooks_fail "unknown hook: $hook"
    return
  }
  if (( ! SF_HOOK_COUNTS[$hook] )); then
    sf_hooks_reset
    reply=( 1 0 '' '' )
    return 0
  fi
  sf_hooks_fail "$label hooks are unavailable"
}

sf_hooks_session_start() {
  sf_hooks_run "$1" session_start '' reject 0 1 || return
  reply=()
}
