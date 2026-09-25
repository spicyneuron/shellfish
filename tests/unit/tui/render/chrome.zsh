#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_FOOTER=test/model
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -ga SF_PRESENT_QUEUE=()
typeset -gi COLUMNS=80 LINES=10

SF_PRESENT_PROFILE='{"tools":["@tools/read_file","/tools/shell"],"sandbox":true}'
typeset banner
COLUMNS=41
banner=$(sf_tui_chat_start startup /tmp/session.jsonl)
[[ $banner == $'\n\e[1m'*$'\n\n\e[1mProject:'* ]] || fail 'wide startup banner was not rendered'
[[ $banner == *$'\e[1mTools:\e[0m read_file, shell'* ]] || fail 'startup tools were not rendered'
[[ $banner == *$'\e[1mSandbox:\e[0m enabled'* ]] || fail 'startup sandbox was not rendered'
[[ $banner != *'Session:'* ]] || fail 'new-session banner included its session path'
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
COLUMNS=80
LINES=10
sf_tui_repaint
typeset permission_prompt=$'─ Allow shell outside of sandbox? ─────────────────────────────────────────────\n\npwd\n\nReason: host access\n\n[a]pprove  [d]eny (default)\n'
[[ $PREDISPLAY == *$permission_prompt ]] || fail 'permission prompt was not rendered'
[[ $POSTDISPLAY == $'\n─'* ]] || fail 'permission prompt omitted its trailing blank line'
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
