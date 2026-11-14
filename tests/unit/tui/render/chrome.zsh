#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_FOOTER=test/model
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -ga SF_PRESENT_QUEUE=()
typeset -gi COLUMNS=80 LINES=10

typeset banner
COLUMNS=41
SHELLFISH_DIR=/tmp/config
banner=$(sf_tui_chat_start startup /tmp/session.jsonl)
[[ $banner == $'\n\e[1m'*$'\n\n\e[1mProject:'* ]] || fail 'wide startup banner was not rendered'
[[ $banner == *$'\e[1mConfig:\e[0m /tmp/config' ]] || fail 'startup config dir was not rendered'
[[ $banner != *'Session:'* ]] || fail 'new-session banner included its session path'

# The session header's details commit as transcript rows, before the first role.
COLUMNS=80
sf_tui_reset
sf_tui_action details 'read_file, shell' '' project/environment 2 1 3 ||
  fail 'cannot present session details'
sf_tui_action message_start system && sf_tui_action message_delta 0 text prompt '' &&
  sf_tui_action message_end || fail 'cannot present a system message'
sf_tui_transcript 79 20 || fail 'rendering the transcript failed'
[[ $SF_PRESENT_VIEWPORT_TEXT == $'Tools: read_file, shell\nCommands: none\nHooks: project/environment\nSandbox: fence'*$', 2 read, 1 write, 3 domain grants\n\n─ system '* ]] ||
  fail "session details were not rendered: $SF_PRESENT_VIEWPORT_TEXT"
sf_tui_reset
sf_tui_action details '' '' '' '' '' '' || fail 'cannot present empty session details'
sf_tui_transcript 79 20 || fail 'rendering the transcript failed'
[[ $SF_PRESENT_VIEWPORT_TEXT == *'Sandbox: disabled'* ]] ||
  fail "disabled sandbox was not rendered: $SF_PRESENT_VIEWPORT_TEXT"
sf_tui_reset
COLUMNS=40
banner=$(sf_tui_chat_start resume /tmp/session.jsonl)
[[ $banner == *$'\n╭───────'* ]] || fail 'narrow startup banner did not stack its art'
[[ $banner == *$'\e[1mSession:\e[0m /tmp/session.jsonl'* ]] ||
  fail 'resume banner omitted its session path'
COLUMNS=43
banner=$(sf_tui_chat_end $'/tmp/my sessions/test.jsonl')
[[ $banner == *"shellfish -s /tmp/my\\ sessions/test.jsonl"* ]] ||
  fail 'exit banner did not quote a session path with spaces'
banner=$(sf_tui_chat_end /tmp/session.jsonl)
[[ $banner == *$'\e[1mResume with:\e[0m'$'\n'"shellfish -s /tmp/session.jsonl"* ]] ||
  fail 'exit banner omitted its resume command'

SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_TOOL=shell
SF_PRESENT_PERMISSION_TEXT=$'pwd\n\nReason: host access'
SF_PRESENT_PERMISSION_DEFAULT=deny
typeset -gi SF_PRESENT_PERMISSION_DEADLINE=$(( SECONDS + 120 ))
COLUMNS=80
LINES=10
sf_tui_repaint
typeset permission_prompt=$'─ Allow shell outside of sandbox? ─────────────────────────────────────────────\npwd\n\nReason: host access\n1. [a]pprove\n2. [d]eny and continue (120s)\n3. [s]top and discuss\n'
[[ $PREDISPLAY == *$permission_prompt ]] || fail 'permission prompt was not rendered'
# The countdown follows the choice that will apply.
SF_PRESENT_PERMISSION_REVIEW='approve: authorized'
SF_PRESENT_PERMISSION_DEFAULT=approve
SF_PRESENT_PERMISSION_DEADLINE=$(( SECONDS + 10 ))
sf_tui_repaint
[[ $PREDISPLAY == *$'Reviewer: approve: authorized\n1. [a]pprove (10s)\n2. [d]eny and continue\n'* ]] ||
  fail 'review verdict and its countdown were not rendered'
SF_PRESENT_PERMISSION_REVIEW=''
SF_PRESENT_PERMISSION_DEFAULT=deny
SF_PRESENT_PERMISSION_DEADLINE=$(( SECONDS + 120 ))
sf_tui_repaint
[[ $POSTDISPLAY == $'\n─'* ]] || fail 'permission prompt omitted its trailing blank line'
SF_PRESENT_PERMISSION_DEADLINE=$(( SECONDS + 119 ))
sf_tui_repaint
[[ $PREDISPLAY == *'2. [d]eny and continue (119s)'* ]] ||
  fail 'permission countdown did not decrease'
SF_PRESENT_PERMISSION_DEADLINE=$(( SECONDS - 1 ))
sf_tui_repaint
[[ $PREDISPLAY == *'2. [d]eny and continue (0s)'* ]] ||
  fail 'expired permission countdown was not clamped to zero'
SF_PRESENT_STATE=idle

SF_PRESENT_QUEUE=( $'first queued\ncontinued' )
sf_tui_repaint
[[ $PREDISPLAY == *$'─ queue '*$'\n1. first queued continued\n'* ]] ||
  fail 'queued prompt was not rendered'
[[ $PREDISPLAY == *'─ queue (ctrl+x to send now) '* ]] ||
  fail 'queue omitted the send-now hint'
SF_PRESENT_STATE=working
sf_tui_repaint
[[ $PREDISPLAY == *'─ queue (ctrl+x to send now) '* ]] ||
  fail 'active turn omitted the queue hint'
COLUMNS=20
sf_tui_repaint
[[ $PREDISPLAY == *$'─ queue ───────────\n'* && $PREDISPLAY != *'ctrl+x'* ]] ||
  fail 'narrow queue header did not omit the hint'
COLUMNS=80
SF_PRESENT_STATE=idle
SF_PRESENT_QUEUE=()
sf_tui_repaint
[[ $PREDISPLAY != *'─ queue '* ]] || fail 'cleared queue remained visible'

SF_PRESENT_HISTORY=( one two )
SF_PRESENT_HISTORY_NO=2
SF_PRESENT_QUEUE=()
sf_tui_repaint
[[ $PREDISPLAY == *'─ history (1/2) '*$'\n❯ ' ]] ||
  fail 'history depth was not rendered in the prompt divider'
SF_PRESENT_HISTORY=()
SF_PRESENT_HISTORY_NO=0

# Queue and completion drawers use the same bounded, safe line layout.
typeset -a reply
sf_tui_drawer 20 3 queue '' one two three four five
assert_equal '─ queue (2 more) ───|one|two|three' "${(j:|:)reply}"
assert_equal 14 "$REPLY"
sf_tui_drawer 20 3 completions '' one two three
assert_equal '─ completions ──────|one|two|three' "${(j:|:)reply}"
sf_tui_drawer 20 3 queue hint
assert_equal 0 "${#reply}"
sf_tui_drawer 5 3 completions '' $'ab\n\tcd\e' '界界界' $'abcde\u0301X'
assert_equal '─ co…|ab  …|界界…|abcd…' "${(j:|:)reply}"
sf_tui_drawer 1 3 completions '' abc 界
assert_equal '…|…|…' "${(j:|:)reply}"

# Narrow headings drop the hint, then the overflow count.
sf_tui_drawer 40 3 queue 'ctrl+x to send now' 1 2 3 4
assert_equal '─ queue (1 more, ctrl+x to send now) ───' "$reply[1]"
sf_tui_drawer 30 3 queue 'ctrl+x to send now' 1 2 3 4
assert_equal '─ queue (1 more) ─────────────' "$reply[1]"
sf_tui_drawer 30 3 queue 'ctrl+x to send now' 1
assert_equal '─ queue (ctrl+x to send now) ─' "$reply[1]"
sf_tui_drawer 10 3 queue 'ctrl+x to send now' 1 2 3 4
assert_equal '─ queue ──' "$reply[1]"
assert_equal 5 "$REPLY"

# Drawers appear above the editor and leave the model footer intact.
SF_PRESENT_COMPLETIONS=( /queue /quit )
sf_tui_repaint
[[ $PREDISPLAY == *$'─ completions '*$'\n  /queue\n  /quit\n─'*$'\n❯ ' ]] ||
  fail 'completion candidates did not render above the editor'
assert_equal test/model "${POSTDISPLAY##*$'\n'}"
assert_equal test/model "$SF_PRESENT_FOOTER"
COLUMNS=10
sf_tui_repaint
[[ $PREDISPLAY == *$'─ comple…\n  /queue\n  /quit\n'* ]] || fail 'narrow drawer was not clipped'
COLUMNS=2
sf_tui_repaint
[[ $PREDISPLAY == *$'…\n…\n…\n'* ]] || fail 'one-column drawer was not clipped'
COLUMNS=80
SF_PRESENT_STATE=permission
sf_tui_repaint
[[ $PREDISPLAY != *completions* ]] || fail 'permission prompt showed completion candidates'
assert_equal test/model "${POSTDISPLAY##*$'\n'}"
SF_PRESENT_STATE=idle
SF_PRESENT_COMPLETIONS=()
sf_tui_repaint
[[ $PREDISPLAY != *completions* ]] || fail 'dismissed drawer remained visible'
assert_equal test/model "${POSTDISPLAY##*$'\n'}"

# Drawer headings mute only the label, so the dashes keep the divider color.
SF_PRESENT_STYLE=( divider fg=D muted fg=M )
typeset -i at
for COLUMNS label in 30 'completions (2)' 6 co…; do
  sf_tui_reset
  SF_PRESENT_COMPLETIONS=( /queue /quit )
  sf_tui_repaint
  at=${#${PREDISPLAY%%─ co*}}
  assert_equal "$at $(( at + COLUMNS - 1 )) fg=D $(( at + 2 )) $(( at + 2 + ${#label} )) fg=M" \
    "${SF_PRESENT_CHROME_HIGHLIGHTS[1,6]}"
done
SF_PRESENT_STYLE=()

# A selection marks and emboldens its line, shows its position, and stays in view.
SF_PRESENT_STYLE=( selected fg=B )
SF_PRESENT_COMPLETIONS=( a b c d e f )
COLUMNS=30
for SF_PRESENT_COMPLETION_NO heading list in \
  0 '(6)' $'  a\n  b\n  c' 1 '(1/6)' $'▸ a\n  b\n  c' 5 '(5/6)' $'  c\n  d\n▸ e'; do
  sf_tui_reset
  SF_PRESENT_COMPLETIONS=( a b c d e f )
  sf_tui_repaint
  [[ $PREDISPLAY == *"─ completions $heading "*$'─\n'"$list"$'\n─'* ]] ||
    fail "selection $SF_PRESENT_COMPLETION_NO was not rendered"
  if (( SF_PRESENT_COMPLETION_NO )); then
    at=${#${PREDISPLAY%%▸*}}
    [[ " ${SF_PRESENT_CHROME_HIGHLIGHTS[*]} " == *" $at $(( at + 3 )) fg=B "* ]] ||
      fail "selection $SF_PRESENT_COMPLETION_NO was not emboldened"
  else
    [[ ${SF_PRESENT_CHROME_HIGHLIGHTS[*]} != *fg=B* ]] || fail 'an unselected list was emboldened'
  fi
done
SF_PRESENT_STYLE=()
SF_PRESENT_COMPLETION_NO=0
SF_PRESENT_COMPLETIONS=()
COLUMNS=80

# The viewport and staging budget use the actual heights of both drawers.
sf_tui_reset
LINES=20
sf_tui_action message_start user
typeset -a transcript_lines=( {1..20} )
sf_tui_action message_delta 0 text "${(F)transcript_lines}" ''
sf_tui_action message_end
sf_tui_repaint
assert_equal 14 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_QUEUE=( queued )
sf_tui_repaint
assert_equal 12 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_COMPLETIONS=( /queue /quit )
sf_tui_repaint
assert_equal 9 "$SF_PRESENT_SAFE_ROWS"
[[ $PREDISPLAY == *$'\n1. queued\n─ completions '* ]] || fail 'drawers did not stack without a gap'
sf_tui_repaint stage
assert_equal 9 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_QUEUE=()
sf_tui_repaint
assert_equal 11 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_COMPLETIONS=()
sf_tui_repaint
assert_equal 14 "$SF_PRESENT_SAFE_ROWS"
