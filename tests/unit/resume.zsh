#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_source libexec/resume/picker.zsh
sf_test_tmp resume

typeset s_empty="$tmp/empty.jsonl"
typeset s_system="$tmp/system.jsonl"
typeset s_context="$tmp/context.jsonl"
typeset s_user="$tmp/user.jsonl"
typeset s_torn="$tmp/torn.jsonl"
typeset s_assistant="$tmp/assistant.jsonl"
typeset s_tool_res="$tmp/tool_res.jsonl"
typeset s_failed="$tmp/failed.jsonl"
typeset s_bad="$tmp/bad.jsonl"
typeset s_state_only="$tmp/state_only.jsonl"
typeset s_state_tail="$tmp/state_tail.jsonl"

make_header() {
  jq -cn '{type:"session",format_version:1,cwd:"/tmp",created:"2026-08-18T10:00:00Z",
    runtime:{request:{model:"claude-3"},
      backend:{name:"custom",command:"/test/run",endpoint:"https://example.invalid"}}}'
}

# Header-only session.
make_header >"$s_empty"

# System preview.
make_header >"$s_system"
print -r -- '{"type":"system","content":"Instructions"}' >>"$s_system"

# Hook context preview.
make_header >"$s_context"
print -r -- '{"type":"hook_result","lifecycle":"session_start","id":"1","name":"test","input":"","user_text":"test · loaded","model_text":"data","exit_code":0}' >>"$s_context"

# User and torn previews.
make_header >"$s_user"
print -r -- '{"type":"user","content":[{"type":"text","text":"list files"}]}' >>"$s_user"

make_header >"$s_torn"
print -n -r -- '{"type":"user","content":[' >>"$s_torn"

# Assistant preview.
make_header >"$s_assistant"
print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"here they are"}]}' >>"$s_assistant"

# Tool result preview.
make_header >"$s_tool_res"
print -r -- '{"type":"tool_result","id":"c1","name":"shell","input":{},"exit_code":2,"user_text":"shell\nerr\nexit 2","model_text":"err\nexit 2"}' >>"$s_tool_res"

# Interrupted turn preview.
make_header >"$s_failed"
print -r -- '{"type":"user","content":[{"type":"text","text":"go"}]}' >>"$s_failed"
print -r -- '{"type":"error","user_text":"Turn interrupted."}' >>"$s_failed"

# Unreadable session preview.
print -r -- 'not json' >"$s_bad"

# State-only preview.
make_header >"$s_state_only"
print -r -- '{"type":"state","name":"preview/only","value":true}' >>"$s_state_only"

# Trailing state preview.
make_header >"$s_state_tail"
print -r -- '{"type":"user","content":[{"type":"text","text":"latest prompt"}]}' >>"$s_state_tail"
print -r -- '{"type":"state","name":"preview/first","value":1}' >>"$s_state_tail"
print -r -- '{"type":"state","name":"preview/last","value":2}' >>"$s_state_tail"

# Summarize resume candidates.
sf_resume_load "$s_empty" "$s_system" "$s_context" "$s_user" "$s_torn" "$s_assistant" "$s_tool_res" \
  "$s_failed" "$s_bad" "$s_state_only" "$s_state_tail"
(( ${#SF_RESUME_PATHS} == 11 ))
(( ${#SF_RESUME_TIMES} == 11 ))
(( ${#SF_RESUME_PAIRS} == 11 ))
(( ${#SF_RESUME_PREVIEWS} == 11 ))

assert_equal custom/claude-3 "$SF_RESUME_PAIRS[1]"
assert_equal '(empty session)' "$SF_RESUME_PREVIEWS[1]"
assert_equal SYSTEM "$SF_RESUME_PREVIEWS[2]"
assert_equal 'test · loaded' "$SF_RESUME_PREVIEWS[3]"
assert_equal 'list files' "$SF_RESUME_PREVIEWS[4]"
assert_equal '(unreadable)' "$SF_RESUME_PREVIEWS[5]"
assert_equal 'here they are' "$SF_RESUME_PREVIEWS[6]"
assert_equal 'shell exit 2' "$SF_RESUME_PREVIEWS[7]"
assert_equal 'Turn interrupted.' "$SF_RESUME_PREVIEWS[8]"
assert_equal '?/?' "$SF_RESUME_PAIRS[9]"
assert_equal '(unreadable)' "$SF_RESUME_PREVIEWS[9]"
assert_equal 'STATE preview/only' "$SF_RESUME_PREVIEWS[10]"
assert_equal 'STATE preview/last' "$SF_RESUME_PREVIEWS[11]"

# Render and accept a changed selection.
zle() { :; }
COLUMNS=60
sf_resume_update_display
[[ $PREDISPLAY == 'Resume session (1 - 11 of 11)'$'\n\n'* &&
   $PREDISPLAY == *$'\n› 1  '* ]] || fail 'resume picker did not render its selection'
KEYS=$'\e[B'
sf_resume_move
BUFFER=''
sf_resume_accept
assert_equal 2 "$BUFFER"

# Route resume selection publicly.
sf_test_tmp resume-command
typeset entry="$ROOT/bin/shellfish" directory error
integer exit_code=0
error=$(zsh -f "$entry" --resume 2>&1) || exit_code=$?
[[ $error == *'resume requires an interactive terminal'* && $exit_code == 2 ]] || \
  fail 'resume picker did not require an interactive terminal'

export XDG_STATE_HOME=$tmp
source "$ROOT/lib/session.zsh"
source "$ROOT/libexec/resume/discovery.zsh"
sf_session_directory
directory=$REPLY
mkdir -p -- "$directory"

make_discovery_header() {
  jq -cn --arg cwd "$1" --arg model "$2" '{type:"session",format_version:1,
    cwd:$cwd,created:"2026-09-04T00:00:00Z",
    runtime:{request:{model:$model}}}'
}
make_discovery_header "$(pwd -P)" first >"$directory/first.jsonl"
touch -t 202609040100 "$directory/first.jsonl"
make_discovery_header "$(pwd -P)" second >"$directory/second.jsonl"
touch -t 202609040200 "$directory/second.jsonl"
make_discovery_header /other/path ignored >"$directory/other.jsonl"
touch -t 202609040300 "$directory/other.jsonl"
print -r -- '{"not":"a session header"}' >"$directory/corrupt.jsonl"
make_discovery_header "$(pwd -P)" hidden >"$directory/.internal.jsonl"

sf_resume_find 0
assert_equal 2 "${#SF_RESUME_MATCHES}"
[[ $SF_RESUME_MATCHES[1] == "$directory/second.jsonl" ]]
[[ $SF_RESUME_MATCHES[2] == "$directory/first.jsonl" ]]
[[ ${SF_RESUME_MATCHES[(I)*.internal.jsonl]} == 0 ]] ||
  fail 'automatic discovery included a leading-dot session'
sf_resume_find 1
assert_equal 1 "${#SF_RESUME_MATCHES}"
[[ $SF_RESUME_MATCHES[1] == "$directory/second.jsonl" ]]
(
  cwd=$(pwd -P)
  export HOME=${cwd:h}
  make_discovery_header "~/${cwd:t}" home >"$directory/home.jsonl"
  touch -t 202609040400 "$directory/home.jsonl"
  sf_resume_find 1
  [[ $SF_RESUME_MATCHES[1] == "$directory/home.jsonl" ]] ||
    fail 'home-relative session cwd was not discovered'
  export HOME=$cwd
  make_discovery_header '~' root >"$directory/root.jsonl"
  touch -t 202609040500 "$directory/root.jsonl"
  sf_resume_find 1
  [[ $SF_RESUME_MATCHES[1] == "$directory/root.jsonl" ]] ||
    fail 'bare home session cwd was not discovered'
)
rm -- "$directory/home.jsonl" "$directory/root.jsonl"
(
  # An unexpandable cwd skips its own session, not the whole directory.
  unset HOME
  make_discovery_header '~/elsewhere' homeless >"$directory/homeless.jsonl"
  touch -t 202609040600 "$directory/homeless.jsonl"
  sf_resume_find 0
  assert_equal 2 "${#SF_RESUME_MATCHES}"
)
rm -- "$directory/homeless.jsonl"
(
  cd "$tmp"
  if sf_resume_find 0 2>/dev/null; then
    fail 'session discovery succeeded with no matches'
  fi
)

exit_code=0
error=$(zsh -f "$entry" --continue --session-out target.jsonl 2>&1) || exit_code=$?
[[ $error == *'--session names an existing session and cannot be combined with --session-out'* && $exit_code == 2 ]] || \
  fail 'continue did not select a session and forward TUI arguments'
