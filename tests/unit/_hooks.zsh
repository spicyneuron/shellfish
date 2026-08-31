source "${0:A:h:h}/_helpers.zsh"
sf_test_source session/main.zsh hooks.zsh
typeset -g SF_ENTRY="$ROOT/bin/shellfish"

typeset hooks captures hook
sf_test_tmp hooks
hooks="$tmp/hooks"
captures="$tmp/captures"
mkdir -p "$hooks" "$captures"
export TMPDIR=$captures
export XDG_STATE_HOME="$tmp/state"

make_hook() {
  local name=$1 body=$2
  hook="$hooks/$name"
  print -r -- '#!/usr/bin/env zsh' >"$hook"
  print -r -- "$body" >>"$hook"
  chmod +x "$hook"
}

run_prompt_hook() {
  local prompt=$1 session=$2
  integer operation_status=0

  sf_session_open "$session" || return
  sf_hooks_user_prompt_submit_locked "$prompt" "$session" || operation_status=1
  sf_session_close || operation_status=1
  return $operation_status
}

assert_no_hook_captures() {
  local root="$captures/shellfish-$EUID/hooks"
  local -a files=( "$root"/capture.*(N) "$root"/input.*(N) )
  (( ${#files} == 0 ))
}
