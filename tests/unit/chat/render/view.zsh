#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source chat/render/nodes.zsh chat/render/highlights.zsh chat/render/rows.zsh \
  chat/render/viewport.zsh chat/render/terminal.zsh chat/render/view.zsh

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
banner=$(sf_chat_chat_start startup /tmp/session.jsonl)
[[ $banner == $'\n\e[1m'*$'\n\n\e[1mProject:'* ]] || fail 'wide startup banner was not rendered'
[[ $banner == *$'\e[1mTools:\e[0m read_file, shell'* ]] || fail 'startup tools were not rendered'
[[ $banner == *$'\e[1mSandbox:\e[0m enabled'* ]] || fail 'startup sandbox was not rendered'
[[ $banner != *'Session:'* ]] || fail 'new-session banner included its session path'
COLUMNS=40
banner=$(sf_chat_chat_start resume /tmp/session.jsonl)
[[ $banner == *$'\n╭───────'* ]] || fail 'narrow startup banner did not stack its art'
[[ $banner == *$'\e[1mSession:\e[0m /tmp/session.jsonl'* ]] ||
  fail 'resume banner omitted its session path'
COLUMNS=43
banner=$(sf_chat_chat_end /tmp/session.jsonl)
assert_equal 42 "${#${banner%%$'\n'*}}"
[[ $banner == *$'\e[1mSaved:\e[0m /tmp/session.jsonl'* ]] || fail 'exit banner omitted its session path'

SF_PRESENT_VIEWPORT_HIGHLIGHTS=( 0 2 bold 3 5 fg=2 )
sf_chat_update_highlights view
assert_equal 'P0 2 bold,P3 5 fg=2' "${(j:,:)region_highlight}"

SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_TOOL=shell
SF_PRESENT_PERMISSION_TEXT=$'pwd\n\nReason: host access'
COLUMNS=80
LINES=10
sf_chat_repaint
typeset permission_prompt=$'─ Allow shell outside of sandbox? ─────────────────────────────────────────────\n\npwd\n\nReason: host access\n\n[a]pprove  [d]eny (default)\n'
[[ $PREDISPLAY == *$permission_prompt ]] || fail 'permission prompt was not rendered'
[[ $POSTDISPLAY == $'\n─'* ]] || fail 'permission prompt omitted its trailing blank line'
SF_PRESENT_STATE=idle

sf_chat_reset
sf_chat_terminal_reset
sf_chat_add message user '' 'alpha beta gamma'
COLUMNS=12
LINES=10
sf_chat_repaint
assert_equal $'alpha beta\ngamma\n\n───────────\n❯ ' "$PREDISPLAY"
COLUMNS=8
sf_chat_repaint
assert_equal $'alpha\nbeta\ngamma\n\n───────\n❯ ' "$PREDISPLAY"

# Flushing rows must not move the prompt: the rows leaving the viewport are
# exactly the lines printed above it. The emptied viewport still paints one row
# from the prefix, which is the row a settled tail has to reserve.
sf_chat_reset
sf_chat_terminal_reset
sf_chat_add message agent '' $'one\ntwo'
COLUMNS=12
sf_chat_repaint
newlines=${PREDISPLAY//[^$'\n']}
integer before=${#newlines}
sf_chat_terminal_stage
staged=( "${(@f)SF_PRESENT_PENDING_TEXT}" )
sf_chat_terminal_finish
sf_chat_repaint
newlines=${PREDISPLAY//[^$'\n']}
assert_equal $before $(( ${#staged} + ${#newlines} ))

sf_chat_reset
sf_chat_terminal_reset
sf_chat_add message agent '' $'hello\n' open
COLUMNS=12
sf_chat_repaint
assert_equal $'hello\n⠃\n\n───────────\n❯ ' "$PREDISPLAY"
sf_chat_close 1
sf_chat_repaint
assert_equal $'hello\n\n───────────\n❯ ' "$PREDISPLAY"

# Legal streaming transitions remain renderable across terminal epochs. Boundary
# newlines stay in the node while the row projection hides them.
typeset close_type suffix detail
integer trailing split width highlight epoch newline
for close_type in message reasoning; do
  for trailing in 0 1 2; do
    suffix=''
    for (( newline = 0; newline < trailing; newline++ )); do suffix+=$'\n'; done
    for split in 0 1; do
      for width in 12 30; do
        for highlight in 0 1; do
          sf_chat_reset
          sf_chat_terminal_reset
          SF_PRESENT_HIGHLIGHT_ENABLED=$highlight
          BUFFER=''
          CURSOR=0
          COLUMNS=$width
          LINES=20
          if [[ $close_type == message ]]; then
            sf_chat_event assistant_delta "hello$suffix"
          else
            sf_chat_event assistant_reasoning_delta "thought$suffix"
          fi
          for epoch in {1..12}; do
            sf_chat_repaint || fail "cannot render open $close_type transition: $trailing/$split/$width/$highlight"
            (( SF_PRESENT_FLUSH_ROWS )) || break
            sf_chat_terminal_stage
            sf_chat_terminal_finish
          done
          (( epoch < 12 )) || fail "open $close_type transition did not settle"
          sf_chat_event assistant_commit
          (( ! split )) || sf_chat_repaint ||
            fail "cannot render closed $close_type transition: $trailing/$width/$highlight"
          sf_chat_event tool_call call_1 shell '{}'
          detail="$close_type transition: $trailing/$split/$width/$highlight"
          sf_chat_repaint || fail "cannot render tool after $detail"
          [[ $PREDISPLAY == *'╰ ⠃'* ]] || fail "tool result missing after $detail"
        done
      done
    done
  done
done
SF_PRESENT_HIGHLIGHT_ENABLED=0
COLUMNS=12
LINES=10

sf_chat_reset
sf_chat_terminal_reset
LINES=3
sf_chat_event backend_request_start
sf_chat_event assistant_delta $'\n'
sf_chat_repaint || fail 'cannot render a newline-only message'
(( SF_PRESENT_FLUSH_ROWS )) || fail 'newline-only message did not stage a prefix'
sf_chat_terminal_stage
sf_chat_terminal_finish
sf_chat_event assistant_reasoning_delta $'\n\n'
sf_chat_repaint || fail 'cannot replace a newline-only message with reasoning'
sf_chat_event assistant_commit
sf_chat_repaint || fail 'cannot close newline-only reasoning'
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"
LINES=10

sf_chat_reset
sf_chat_terminal_reset
sf_chat_add activity '' '' '' open
sf_chat_repaint
assert_equal $'⠃\n\n───────────\n❯ ' "$PREDISPLAY"
sf_chat_event backend_request_start
sf_chat_repaint
assert_equal $'─ agent ───\n\n⠃\n\n───────────\n❯ ' "$PREDISPLAY"

# A collapsed node keeps its row when it closes.
sf_chat_reset
sf_chat_terminal_reset
SF_PRESENT_PREVIEW_REASONING=0
sf_chat_add reasoning agent '' 'thought' open
COLUMNS=30
sf_chat_repaint
assert_equal $'✎ Thinking… ⠃\n\n─────────────────────────────\n❯ ' "$PREDISPLAY"
sf_chat_close 1
sf_chat_repaint
assert_equal $'✎ Thought for ~2 tokens.\n\n─────────────────────────────\n❯ ' "$PREDISPLAY"
SF_PRESENT_PREVIEW_REASONING=full

# An expanded node shows its own tail while the body is empty, so arriving
# content grows the viewport by exactly the rows it adds.
sf_chat_reset
sf_chat_terminal_reset
sf_chat_add reasoning agent '' '' open
sf_chat_repaint
assert_equal $'✎ Reasoning\n  ⠃\n\n─────────────────────────────\n❯ ' "$PREDISPLAY"
sf_chat_append 1 thought
sf_chat_repaint
assert_equal $'✎ Reasoning\n  thought\n  ⠃\n\n─────────────────────────────\n❯ ' "$PREDISPLAY"

# A line crossing many visual rows is scanned one row at a time. The growing
# line is never rescanned, so the work stays proportional to the text rather
# than to the text times the number of rows it has filled.
sf_chat_reset
sf_chat_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_HIGHLIGHT_ENABLED=1
typeset -gi stream_chars=0
functions[sf_chat_markdown_saved]=$functions[sf_chat_markdown_highlight]
sf_chat_markdown_highlight() {
  (( stream_chars += ${#1} ))
  sf_chat_markdown_saved "$@"
}
sf_chat_add message agent '' '' open
COLUMNS=20
LINES=12
typeset -i chunk
for (( chunk = 1; chunk <= 24; chunk++ )); do
  sf_chat_append 1 'lorem ipsum '
  sf_chat_repaint
  if (( SF_PRESENT_FLUSH_ROWS )); then
    sf_chat_terminal_stage
    sf_chat_terminal_finish
  fi
done
typeset -i streamed=$(( 24 * 12 ))
(( stream_chars <= 2 * streamed )) ||
  fail "rescanned the growing line: $stream_chars scanned for $streamed streamed"
(( SF_PRESENT_NODE_FRONTIER[1] > 0 )) || fail 'no row boundary was ever released'

# Completing the line, closing the node, and resizing each settle the remainder
# without going back over what the row boundaries already covered.
typeset -i before_completion=$stream_chars
sf_chat_append 1 $'tail\n'
sf_chat_repaint
COLUMNS=12
sf_chat_repaint
sf_chat_close 1
sf_chat_repaint
(( stream_chars - before_completion <= 2 * COLUMNS + 5 )) ||
  fail "completion rescanned the line: $(( stream_chars - before_completion ))"
functions[sf_chat_markdown_highlight]=$functions[sf_chat_markdown_saved]
unfunction sf_chat_markdown_saved
SF_PRESENT_HIGHLIGHT_ENABLED=0
COLUMNS=80
LINES=10

# Chrome offsets index PREDISPLAY + BUFFER + POSTDISPLAY, so confirm each span
# actually covers the text it claims rather than trusting the arithmetic.
SF_PRESENT_STYLE=( divider 'fg=8' prompt 'fg=4' footer 'fg=5' muted 'fg=7'
  permission 'fg=4,bold' permission.divider 'fg=4' syntax.string 'fg=6' )
sf_chat_reset
SF_PRESENT_IDENTITY=test/model
SF_PRESENT_FOOTER='test/model · 1 ↑ 2 ↓'
COLUMNS=80
LINES=10
SF_PRESENT_STATE=idle
SF_PRESENT_QUEUE=()
BUFFER=draft
CURSOR=5
sf_chat_repaint
typeset chrome_display="$PREDISPLAY$BUFFER$POSTDISPLAY"
typeset -a chrome_sliced=() chrome_styled=()
integer index
for (( index = 1; index <= ${#SF_PRESENT_CHROME_HIGHLIGHTS}; index += 3 )); do
  chrome_sliced+=( "${chrome_display[SF_PRESENT_CHROME_HIGHLIGHTS[index] + 1,SF_PRESENT_CHROME_HIGHLIGHTS[index + 1]]}" )
  chrome_styled+=( "$SF_PRESENT_CHROME_HIGHLIGHTS[index + 2]" )
done
assert_equal "${(l:79::─:)""}|❯ |${(l:79::─:)""}|test/model · 1 ↑ 2 ↓" \
  "${(j:|:)chrome_sliced}"
assert_equal 'fg=8,fg=4,fg=8,fg=5' "${(j:,:)chrome_styled}"

SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_TOOL=shell
SF_PRESENT_PERMISSION_TEXT=$'echo "hi"\n\nReason: "host"'
SF_PRESENT_PERMISSION_LANGUAGE=sh
SF_PRESENT_PERMISSION_PREVIEW_LENGTH=9
sf_chat_repaint
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
assert_equal 'fg=4,bold' "$chrome_styled[3]"
assert_equal "${(l:79::─:)""}" "$chrome_sliced[4]"
assert_equal 'fg=4' "$chrome_styled[4]"
[[ ${(j:,:)chrome_sliced} != *'"host"'* ]] || fail 'permission reason was syntax highlighted'
SF_PRESENT_STATE=idle

# The queue divider, title, and items carry their respective styles.
SF_PRESENT_QUEUE=( $'first queued\ncontinued' )
sf_chat_repaint
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
sf_chat_repaint
[[ $PREDISPLAY != *'─ queue '* ]] || fail 'cleared queue remained visible'

SF_PRESENT_HISTORY=( one two )
SF_PRESENT_HISTORY_NO=2
SF_PRESENT_QUEUE=()
sf_chat_repaint
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
