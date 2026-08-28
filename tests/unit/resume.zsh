#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_source resume.zsh
sf_test_tmp resume

typeset s_empty="$tmp/empty.jsonl"
typeset s_system="$tmp/system.jsonl"
typeset s_context="$tmp/context.jsonl"
typeset s_user="$tmp/user.jsonl"
typeset s_torn="$tmp/torn.jsonl"
typeset s_assistant="$tmp/assistant.jsonl"
typeset s_tool_res="$tmp/tool_res.jsonl"
typeset s_bad="$tmp/bad.jsonl"

make_header() {
  jq -cn '{type:"session",format_version:1,cwd:"/tmp",created:"2026-08-18T10:00:00Z",profile:{request:{model:"claude-3"}},backend:{name:"custom",command:"/test/run",endpoint:"https://example.invalid"}}'
}

# 1. Header only
make_header >"$s_empty"

# 2. System message
make_header >"$s_system"
print -r -- '{"type":"system","content":"Instructions"}' >>"$s_system"

# 3. Context record
make_header >"$s_context"
print -r -- '{"type":"context","tag":"env","hook":"test","content":"data"}' >>"$s_context"

# 4. User message
make_header >"$s_user"
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"list files"}]}' >>"$s_user"

make_header >"$s_torn"
print -n -r -- '{"type":"message","role":"user","content":[' >>"$s_torn"

# 5. Assistant message
make_header >"$s_assistant"
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"here they are"}]}' >>"$s_assistant"

# 6. Tool result with exit code
make_header >"$s_tool_res"
print -r -- '{"type":"message","role":"tool_result","call_id":"c1","name":"shell","content":"err","exit_code":2}' >>"$s_tool_res"

# 7. Unreadable file
print -r -- 'not json' >"$s_bad"

# Loading sessions summarizes records and formats resume labels.
sf_resume_load "$s_empty" "$s_system" "$s_context" "$s_user" "$s_torn" "$s_assistant" "$s_tool_res" "$s_bad"
(( ${#SF_RESUME_PATHS} == 8 ))
(( ${#SF_RESUME_TIMES} == 8 ))
(( ${#SF_RESUME_PAIRS} == 8 ))
(( ${#SF_RESUME_PREVIEWS} == 8 ))

assert_equal custom/claude-3 "$SF_RESUME_PAIRS[1]"
assert_equal '(empty session)' "$SF_RESUME_PREVIEWS[1]"
assert_equal SYSTEM "$SF_RESUME_PREVIEWS[2]"
assert_equal ENV "$SF_RESUME_PREVIEWS[3]"
assert_equal 'list files' "$SF_RESUME_PREVIEWS[4]"
assert_equal '(unreadable)' "$SF_RESUME_PREVIEWS[5]"
assert_equal 'here they are' "$SF_RESUME_PREVIEWS[6]"
assert_equal 'shell exit 2' "$SF_RESUME_PREVIEWS[7]"
assert_equal '?/?' "$SF_RESUME_PAIRS[8]"
assert_equal '(unreadable)' "$SF_RESUME_PREVIEWS[8]"

# A session removed after discovery does not shift later summaries onto its row.
sf_resume_load "$s_empty" "$tmp/missing.jsonl" "$s_system"
assert_equal '(unreadable)' "$SF_RESUME_PREVIEWS[2]"
assert_equal SYSTEM "$SF_RESUME_PREVIEWS[3]"
sf_resume_load "$s_empty" "$s_system" "$s_context" "$s_user" "$s_torn" "$s_assistant" "$s_tool_res" "$s_bad"

# sf_resume_update_display sets PREDISPLAY with the numbered candidate list.
zle() { :; }
COLUMNS=60
sf_resume_update_display
[[ $PREDISPLAY == 'Resume session (1 - 8 of 8)'$'\n\n'* ]]
[[ $PREDISPLAY == *$'\n› 1  '* ]]
[[ $PREDISPLAY == *'2026-08-18 10:00'* ]]
[[ $PREDISPLAY == *'custom/claude-3'* ]]
[[ $PREDISPLAY == *'↑/↓ select  ←/→ page  0–9 jump  Enter resumes  Esc cancels'* ]]
for line in ${(f)PREDISPLAY}; do (( ${#line} < COLUMNS )); done

# Each highlight must cover exactly the text it decorates, so a span whose
# offsets drift off its row fails even when the attributes are still correct.
span_text() {
  local -a span=( ${=1} )
  REPLY=${PREDISPLAY[${span[1]#P} + 1,${span[2]}]}
}
span_text "$region_highlight[1]"
assert_equal 'Resume session (1 - 8 of 8)' "$REPLY"
[[ $region_highlight[1] == *' bold' ]]
span_text "$region_highlight[2]"
[[ $REPLY == '› 1  '* ]]
[[ $region_highlight[2] == *' standout' ]]
span_text "$region_highlight[3]"
assert_equal '↑/↓ select  ←/→ page  0–9 jump  Enter resumes  Esc cancels' "$REPLY"
[[ $region_highlight[3] == *' fg=8' ]]

# The preview receives space unused by the backend/model column.
(
  SF_RESUME_PATHS=( "$s_empty" )
  SF_RESUME_TIMES=( '2026-08-18 10:00' )
  SF_RESUME_PAIRS=( 'x/y' )
  SF_RESUME_PREVIEWS=( '12345678901234567890' )
  COLUMNS=50
  sf_resume_update_display
  [[ $PREDISPLAY == *'12345678901234567890'* ]]
)

# Very narrow displays preserve preview space by truncating backend/model.
(
  SF_RESUME_PATHS=( "$s_empty" )
  SF_RESUME_TIMES=( '2026-08-18 10:00' )
  SF_RESUME_PAIRS=( 'very-long-backend/very-long-model' )
  SF_RESUME_PREVIEWS=( 'P' )
  COLUMNS=28
  sf_resume_update_display
  [[ $PREDISPLAY == *'…  P'$'\n'* ]]
)

# Arrow movement changes the highlighted default without editing a buffer.
KEYS=$'\e[B'
sf_resume_move
assert_equal 2 "$SF_RESUME_SELECTED"
[[ $PREDISPLAY == *$'\n› 2  '* ]]

# Accept uses the highlighted row.
BUFFER=''
sf_resume_accept
assert_equal 2 "$BUFFER"

# Pages summarize ten sessions at a time, and 0 selects the tenth row.
SF_RESUME_ALL_PATHS=( "$s_empty" "$s_system" "$s_context" "$s_user" "$s_torn"
  "$s_assistant" "$s_tool_res" "$s_bad" "$s_empty" "$s_system" "$s_context" )
SF_RESUME_LIMIT=10
SF_RESUME_PAGE=0
sf_resume_load_page
(( ${#SF_RESUME_PATHS} == 10 ))
KEYS=0
sf_resume_jump
assert_equal 10 "$BUFFER"
KEYS=$'\e[C'
sf_resume_change_page
assert_equal 1 "$SF_RESUME_PAGE"
(( ${#SF_RESUME_PATHS} == 1 ))
KEYS=$'\e[D'
sf_resume_change_page
assert_equal 0 "$SF_RESUME_PAGE"
(( ${#SF_RESUME_PATHS} == 10 ))

# Cancel marks cancellation.
sf_resume_cancel
assert_equal 1 "$SF_RESUME_CANCELLED"
