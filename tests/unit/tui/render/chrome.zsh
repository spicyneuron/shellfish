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
sf_tui_action details 'read_file, shell' '' project/environment 2 1 ||
  fail 'cannot present session details'
sf_tui_action message_start system && sf_tui_action message_delta 0 text prompt '' &&
  sf_tui_action message_end || fail 'cannot present a system message'
sf_tui_transcript 79 20 || fail 'rendering the transcript failed'
[[ $SF_PRESENT_VIEWPORT_TEXT == $'Tools: read_file, shell\nCommands: none\nHooks: project/environment\nSandbox: fence'*$', 2 read and 1 write grants\n\n─ system '* ]] ||
  fail "session details were not rendered: $SF_PRESENT_VIEWPORT_TEXT"
sf_tui_reset
sf_tui_action details '' '' '' '' '' || fail 'cannot present empty session details'
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
typeset -gi SF_PRESENT_PERMISSION_DEADLINE=$(( SECONDS + 120 ))
COLUMNS=80
LINES=10
sf_tui_repaint
typeset permission_prompt=$'─ Allow shell outside of sandbox? ─────────────────────────────────────────────\n\npwd\n\nReason: host access\n\n1. [a]pprove\n2. [d]eny and continue (120s)\n3. [s]top and discuss\n'
[[ $PREDISPLAY == *$permission_prompt ]] || fail 'permission prompt was not rendered'
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
SF_PRESENT_QUEUE=()
sf_tui_repaint
[[ $PREDISPLAY != *'─ queue '* ]] || fail 'cleared queue remained visible'

SF_PRESENT_HISTORY=( one two )
SF_PRESENT_HISTORY_NO=2
SF_PRESENT_QUEUE=()
sf_tui_repaint
[[ $PREDISPLAY == *'─ history 1/2 '*$'\n❯ ' ]] ||
  fail 'history depth was not rendered in the prompt divider'
SF_PRESENT_HISTORY=()
SF_PRESENT_HISTORY_NO=0
