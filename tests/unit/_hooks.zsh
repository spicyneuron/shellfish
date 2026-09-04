source "${0:A:h:h}/_helpers.zsh"
sf_test_source session/main.zsh hooks.zsh
typeset -g SF_ENTRY="$ROOT/bin/shellfish"

typeset scripts captures script
sf_test_tmp hooks
scripts="$tmp/hooks"
captures="$tmp/captures"
mkdir -p "$scripts" "$captures"
export TMPDIR=$captures
export XDG_STATE_HOME="$tmp/state"

make_script() {
  local name=$1 body=$2
  script="$scripts/$name"
  print -r -- '#!/usr/bin/env zsh' >"$script"
  print -r -- "$body" >>"$script"
  chmod +x "$script"
}

run_prompt_hook() {
  local prompt=$1 session=$2 context
  integer operation_status=0

  sf_session_begin_turn "$session" || return
  sf_hooks_user_prompt_submit "$prompt" "$session" || operation_status=1
  if (( ! operation_status )); then
    for context in "${SF_HOOK_CONTEXT_RECORDS[@]}"; do
      sf_session_append "$context" || { operation_status=1; break; }
    done
  fi
  sf_session_reset
  return $operation_status
}

assert_no_hook_captures() {
  local root="$captures/shellfish-$EUID/hooks"
  local -a files=( "$root"/capture.*(N) "$root"/input.*(N) )
  (( ${#files} == 0 ))
}
