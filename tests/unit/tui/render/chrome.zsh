#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/terminal.zsh \
  libexec/tui/render/view.zsh

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_FOOTER=test/model
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -g SF_PRESENT_PERMISSION_LANGUAGE=''
typeset -gi SF_PRESENT_PERMISSION_PREVIEW_LENGTH=0
typeset -ga SF_PRESENT_QUEUE=()
typeset -gi COLUMNS=80 LINES=10

SF_PRESENT_RUNTIME='{
  "harness": {
    "tools": [{"name":"read_file"},{"name":"shell"}],
    "sandbox": true
  }
}'
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
banner=$(sf_tui_chat_end /tmp/session.jsonl)
assert_equal 42 "${#${banner%%$'\n'*}}"
[[ $banner == *$'\e[1mSaved:\e[0m /tmp/session.jsonl'* ]] || fail 'exit banner omitted its session path'

SF_PRESENT_VIEWPORT_HIGHLIGHTS=( 0 2 bold 3 5 fg=2 )
sf_tui_update_highlights view
assert_equal 'P0 2 bold,P3 5 fg=2' "${(j:,:)region_highlight}"

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

# Chrome offsets index PREDISPLAY + BUFFER + POSTDISPLAY, so confirm each span
# actually covers the text it claims rather than trusting the arithmetic.
SF_PRESENT_STYLE=( divider 'fg=8' prompt_waiting 'fg=2' prompt 'fg=4' footer 'fg=5'
  muted 'fg=7' permission 'fg=4' syntax.string 'fg=6' )
sf_tui_reset
SF_PRESENT_IDENTITY=test/model
SF_PRESENT_FOOTER='test/model · 1 ↑ 2 ↓'
COLUMNS=80
LINES=10
SF_PRESENT_STATE=idle
SF_PRESENT_QUEUE=()
BUFFER=draft
CURSOR=5
sf_tui_repaint
typeset chrome_display="$PREDISPLAY$BUFFER$POSTDISPLAY"
typeset -a chrome_sliced=() chrome_styled=()
integer index
for (( index = 1; index <= ${#SF_PRESENT_CHROME_HIGHLIGHTS}; index += 3 )); do
  chrome_sliced+=( "${chrome_display[SF_PRESENT_CHROME_HIGHLIGHTS[index] + 1,SF_PRESENT_CHROME_HIGHLIGHTS[index + 1]]}" )
  chrome_styled+=( "$SF_PRESENT_CHROME_HIGHLIGHTS[index + 2]" )
done
assert_equal "${(l:79::─:)""}|❯ |${(l:79::─:)""}|test/model · 1 ↑ 2 ↓" \
  "${(j:|:)chrome_sliced}"
assert_equal 'fg=2,fg=2,fg=2,fg=5' "${(j:,:)chrome_styled}"

# Neither an accepted prompt, which repaints before the controller can leave
# idle, nor a live turn, which queues instead, is waiting on input.
for SF_PRESENT_ACTION SF_PRESENT_STATE in submit idle '' working; do
  sf_tui_repaint
  chrome_styled=()
  for (( index = 3; index <= ${#SF_PRESENT_CHROME_HIGHLIGHTS}; index += 3 )); do
    chrome_styled+=( "$SF_PRESENT_CHROME_HIGHLIGHTS[index]" )
  done
  [[ ${(j:,:)chrome_styled} == 'fg=4,fg=4,fg=4,fg=5' ]] ||
    fail "state '$SF_PRESENT_STATE' action '$SF_PRESENT_ACTION' chrome: ${(j:,:)chrome_styled}"
done
SF_PRESENT_ACTION=''

SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_TOOL=shell
SF_PRESENT_PERMISSION_TEXT=$'echo "hi"\n\nReason: "host"'
SF_PRESENT_PERMISSION_LANGUAGE=sh
SF_PRESENT_PERMISSION_PREVIEW_LENGTH=9
sf_tui_repaint
chrome_display="$PREDISPLAY$BUFFER$POSTDISPLAY"
chrome_sliced=()
chrome_styled=()
for (( index = 1; index <= ${#SF_PRESENT_CHROME_HIGHLIGHTS}; index += 3 )); do
  chrome_sliced+=( "${chrome_display[SF_PRESENT_CHROME_HIGHLIGHTS[index] + 1,SF_PRESENT_CHROME_HIGHLIGHTS[index + 1]]}" )
  chrome_styled+=( "$SF_PRESENT_CHROME_HIGHLIGHTS[index + 2]" )
done
assert_equal '"hi"' "$chrome_sliced[2]"
assert_equal 'fg=6' "$chrome_styled[2]"
assert_equal '[a]pprove  [d]eny (default)' "$chrome_sliced[3]"
assert_equal 'fg=4' "$chrome_styled[3]"
assert_equal "${(l:79::─:)""}" "$chrome_sliced[4]"
assert_equal 'fg=4' "$chrome_styled[4]"
# The labelled top rule is the same divider as the bottom, so it shares a style.
assert_equal 79 ${#chrome_sliced[1]}
[[ $chrome_sliced[1] == '─ Allow shell outside of sandbox? '─* ]] ||
  fail "top rule: $chrome_sliced[1]"
assert_equal "$chrome_styled[4]" "$chrome_styled[1]"
[[ ${(j:,:)chrome_sliced} != *'"host"'* ]] || fail 'permission reason was syntax highlighted'
SF_PRESENT_STATE=idle

# The queue divider, title, and items carry their respective styles.
SF_PRESENT_QUEUE=( $'first queued\ncontinued' )
sf_tui_repaint
chrome_display="$PREDISPLAY$BUFFER$POSTDISPLAY"
chrome_sliced=()
chrome_styled=()
for (( index = 1; index <= ${#SF_PRESENT_CHROME_HIGHLIGHTS}; index += 3 )); do
  chrome_sliced+=( "${chrome_display[SF_PRESENT_CHROME_HIGHLIGHTS[index] + 1,SF_PRESENT_CHROME_HIGHLIGHTS[index + 1]]}" )
  chrome_styled+=( "$SF_PRESENT_CHROME_HIGHLIGHTS[index + 2]" )
done
assert_equal "─ queue ${(l:71::─:)""}" "$chrome_sliced[1]"
assert_equal 'fg=8' "$chrome_styled[1]"
assert_equal 'queue' "$chrome_sliced[2]"
assert_equal 'fg=7' "$chrome_styled[2]"
assert_equal '1. first queued continued' "$chrome_sliced[3]"
assert_equal 'fg=7' "$chrome_styled[3]"
SF_PRESENT_QUEUE=()
sf_tui_repaint
[[ $PREDISPLAY != *'─ queue '* ]] || fail 'cleared queue remained visible'

SF_PRESENT_HISTORY=( one two )
SF_PRESENT_HISTORY_NO=2
SF_PRESENT_QUEUE=()
sf_tui_repaint
[[ $PREDISPLAY == *'─ history 1/2 '*$'\n❯ ' ]] ||
  fail 'history depth was not rendered in the prompt divider'
chrome_display="$PREDISPLAY$BUFFER$POSTDISPLAY"
chrome_sliced=()
chrome_styled=()
for (( index = 1; index <= ${#SF_PRESENT_CHROME_HIGHLIGHTS}; index += 3 )); do
  chrome_sliced+=( "${chrome_display[SF_PRESENT_CHROME_HIGHLIGHTS[index] + 1,SF_PRESENT_CHROME_HIGHLIGHTS[index + 1]]}" )
  chrome_styled+=( "$SF_PRESENT_CHROME_HIGHLIGHTS[index + 2]" )
done
assert_equal 'history 1/2' "$chrome_sliced[2]"
assert_equal 'fg=7' "$chrome_styled[2]"
SF_PRESENT_HISTORY=()
SF_PRESENT_HISTORY_NO=0
