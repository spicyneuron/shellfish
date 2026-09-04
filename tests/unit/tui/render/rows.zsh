#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/nodes.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/rows.zsh

typeset presentation='{"tui":{"preview_lines_reasoning":"full","preview_lines_context":"full","preview_lines_tool_call":"full","preview_lines_tool_result":"full"}}'
sf_tui_rows_config "$presentation"

sf_tui_event user abcdef
sf_tui_event assistant_delta xyz
sf_tui_rows 8 20
assert_equal $'─ user ─\n\nabcdef\n\n─ agent \n\n⠃' "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal '2:0,2:1,3:0,3:1,4:0,4:1,4:4' "${(j:,:)SF_PRESENT_ROW_CURSOR}"
assert_equal '1,1,1,1,1,1,0' "${(j:,:)SF_PRESENT_ROW_SETTLED}"
assert_equal "${#SF_PRESENT_ROW_TEXT}" "${#SF_PRESENT_ROW_KIND}"
assert_equal "${#SF_PRESENT_ROW_TEXT}" "${#SF_PRESENT_ROW_HIGHLIGHTS}"
assert_equal "${#SF_PRESENT_ROW_TEXT}" "${#SF_PRESENT_ROW_SOURCE_END}"
assert_equal '1,2,2,3,3,4,4' "${(j:,:)SF_PRESENT_ROW_NODE}"
assert_equal 'section.user,separator,message.user,separator,section.agent,separator,message.agent' \
  "${(j:,:)SF_PRESENT_ROW_KIND}"

sf_tui_rows 8 2
assert_equal $'─ user ─\n' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_rows 8 20 2:1
assert_equal $'abcdef\n\n─ agent \n\n⠃' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_event assistant_commit
sf_tui_rows 8 20 4:2
assert_equal yz "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal 5:0 "$SF_PRESENT_ROW_CURSOR[-1]"
assert_equal 1 "$SF_PRESENT_ROW_SETTLED[-1]"

sf_tui_reset
sf_tui_add message agent '' 'hello world' open
sf_tui_rows 5 20
assert_equal $'hello\n⠃' "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal '1:6,1:11' "${(j:,:)SF_PRESENT_ROW_CURSOR}"
sf_tui_close 1
sf_tui_rows 5 20 1:6
assert_equal world "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message agent '' $'\n\nhello\n\n' open
sf_tui_set_frontier 1 8
sf_tui_rows 80 20
assert_equal $'hello\n⠃' "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal 8 "$SF_PRESENT_ROW_SOURCE_END[1]"
assert_equal $'\n\nhello\n\n' "$SF_PRESENT_NODE_BODY[1]"
sf_tui_stream message world
sf_tui_close 1
sf_tui_rows 80 20
assert_equal $'hello\n\nworld' "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal $'\n\nhello\n\nworld' "$SF_PRESENT_NODE_BODY[1]"

sf_tui_reset
sf_tui_add message agent '' $'hello\nworld' open
sf_tui_rows 80 20
assert_equal $'hello\n⠃' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message agent '' $'first\nsecond\npartial' open
sf_tui_set_frontier 1 6
sf_tui_rows 80 20
assert_equal '1,0' "${(j:,:)SF_PRESENT_ROW_SETTLED[1,2]}"

sf_tui_reset
sf_tui_add reasoning agent '' $'\nfirst\nsecond\n' open
sf_tui_set_frontier 1 7
sf_tui_rows 80 20
assert_equal '1,1,0' "${(j:,:)SF_PRESENT_ROW_SETTLED[1,3]}"

sf_tui_reset
sf_tui_event context project_environment session_start '<env>test</env>'
sf_tui_event user ''
sf_tui_rows 80 20
assert_equal $'↪ project_environment · session_start\n  <env>test</env>' \
  "${(F)SF_PRESENT_ROW_TEXT[1,2]}"
assert_equal '─ user ───────────────────────────────────────────────────────────────────── 1 ─' "$SF_PRESENT_ROW_TEXT[-1]"

sf_tui_reset
sf_tui_event tool_call call_1 shell for
sf_tui_event tool_result call_1 0 ok
sf_tui_rows 80 20
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n⛭ shell\n│ for\n╰ ok\n  exit 0' "${(F)SF_PRESENT_ROW_TEXT}"

# An expanded tool can settle its heading before a result exists. Its activity
# is display-only: the cursor stays at the body boundary so the result is not
# skipped when it arrives.
sf_tui_reset
sf_tui_event tool_call call_open shell run
sf_tui_rows 80 20
assert_equal $'│ run\n╰ ⠃' "${(F)SF_PRESENT_ROW_TEXT[-2,-1]}"
assert_equal 3:0 "$SF_PRESENT_ROW_CURSOR[-1]"
assert_equal 0 "$SF_PRESENT_ROW_SETTLED[-1]"
sf_tui_event tool_result call_open 0 result
sf_tui_rows 80 20 3:0
assert_equal $'╰ result\n  exit 0' "${(F)SF_PRESENT_ROW_TEXT}"

# A detected sandbox denial joins the result footer rather than standing on its own.
sf_tui_reset
sf_tui_event tool_call call_denial shell run
sf_tui_event tool_result call_denial 1 denied '' '' sandbox_denial
sf_tui_rows 80 20
assert_equal '  exit 1 · sandbox denial detected' "$SF_PRESENT_ROW_TEXT[-1]"

# A zero preview is a collapsed, single-row projection. Its open form remains
# wholly active, then its completed form settles without wrapping the body.
presentation='{"tui":{"preview_lines_reasoning":0,"preview_lines_context":0,"preview_lines_tool_call":0,"preview_lines_tool_result":0}}'
sf_tui_rows_config "$presentation"
sf_tui_reset
sf_tui_event assistant_reasoning_delta $'one\ntwo\nthree'
sf_tui_rows 80 20
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n✎ Thinking… ⠃' \
  "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal 0 "$SF_PRESENT_ROW_SETTLED[-1]"
sf_tui_event assistant_commit
sf_tui_rows 80 20 2:1
assert_equal '✎ Thought for ~4 tokens.' "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal 1 "$SF_PRESENT_ROW_SETTLED[-1]"

sf_tui_reset
sf_tui_event user done
sf_tui_add activity '' '' '' open
sf_tui_rows 80 20
assert_equal $'─ user ───────────────────────────────────────────────────────────────────── 1 ─\n\ndone\n\n⠃' \
  "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal '0,0' "${(j:,:)SF_PRESENT_ROW_SETTLED[-2,-1]}"

sf_tui_reset
sf_tui_event tool_call call_zero shell 'make test'
sf_tui_rows 80 20
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n⛭ shell\n╰ ⠃' \
  "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal 0 "$SF_PRESENT_ROW_SETTLED[-1]"
sf_tui_event tool_result call_zero 1 $'failure\ndetail'
sf_tui_rows 80 20 3:0
assert_equal '╰ … · exit 1' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_event tool_call call_zero_denial shell 'make test'
sf_tui_event tool_result call_zero_denial 1 failure '' '' sandbox_denial
sf_tui_rows 80 20
assert_equal '╰ … · exit 1 · sandbox denial detected' "$SF_PRESENT_ROW_TEXT[-1]"

sf_tui_reset
sf_tui_event tool_call call_empty read_file path
sf_tui_event tool_result call_empty hidden ''
sf_tui_rows 80 20
assert_equal $'⛭ read_file\n╰' "${(F)SF_PRESENT_ROW_TEXT[-2,-1]}"

sf_tui_reset
sf_tui_event context project_environment session_start $'one\ntwo'
sf_tui_rows 80 20
assert_equal '↪ project_environment · session_start · ~2 tokens' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_event system $'one\ntwo'
sf_tui_rows 80 20
assert_equal 3 "${#SF_PRESENT_ROW_TEXT}"
assert_equal '… ~2 tokens' "$SF_PRESENT_ROW_TEXT[-1]"
[[ ${(F)SF_PRESENT_ROW_TEXT} != *one* && ${(F)SF_PRESENT_ROW_TEXT} != *two* ]] ||
  fail 'zero system preview exposed the message body'

# Positive preview limits visible terminal rows, reports tokens, and does not
# count or expose hidden rows. Failed tools use the same clamp as successes.
presentation='{"tui":{"preview_lines_reasoning":1,"preview_lines_context":1,"preview_lines_tool_call":1,"preview_lines_tool_result":1}}'
sf_tui_rows_config "$presentation"
sf_tui_reset
sf_tui_event assistant_reasoning_delta $'first\nsecond'
sf_tui_rows 80 20
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n✎ Reasoning\n  first\n  … ~3 tokens ⠃' \
  "${(F)SF_PRESENT_ROW_TEXT}"
sf_tui_event reasoning_tokens 4
sf_tui_event assistant_commit
sf_tui_rows 80 20
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n✎ Reasoning\n  first\n  … Thought for ~4 tokens.' \
  "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_event context hook project $'alpha beta\ngamma\ndelta'
sf_tui_rows 16 20
assert_equal $'↪ hook · project\n  alpha beta\n  … ~6 tokens' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_rows 16 2
assert_equal '1:t:0:1' "$SF_PRESENT_ROW_CURSOR[-1]"
sf_tui_rows 8 20 "$SF_PRESENT_ROW_CURSOR[-1]"
typeset resized_preview=${(F)SF_PRESENT_ROW_TEXT}
[[ $resized_preview != *gamma* && $resized_preview != *delta* ]] ||
  fail 'resize granted a fresh preview budget to hidden context'

sf_tui_reset
sf_tui_event system $'first row\nsecond row\nthird row'
sf_tui_rows 80 20
assert_equal 4 "${#SF_PRESENT_ROW_TEXT}"
assert_equal 'first row' "$SF_PRESENT_ROW_TEXT[-2]"
assert_equal '… ~8 tokens' "$SF_PRESENT_ROW_TEXT[-1]"
[[ ${(F)SF_PRESENT_ROW_TEXT} != *'second row'* && ${(F)SF_PRESENT_ROW_TEXT} != *'third row'* ]] ||
  fail 'system preview exposed hidden message rows'
sf_tui_rows 80 3
assert_equal '2:t:0:1' "$SF_PRESENT_ROW_CURSOR[-1]"
sf_tui_rows 8 20 "$SF_PRESENT_ROW_CURSOR[-1]"
[[ ${(F)SF_PRESENT_ROW_TEXT} != *second* && ${(F)SF_PRESENT_ROW_TEXT} != *third* ]] ||
  fail 'resize exposed hidden system message rows'

sf_tui_reset
sf_tui_event tool_call call_preview shell run
sf_tui_event tool_result call_preview 1 $'first row\nsecond row\nthird row'
sf_tui_rows 80 20
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n⛭ shell\n│ run\n╰ first row\n  … ~8 tokens · exit 1' \
  "${(F)SF_PRESENT_ROW_TEXT}"
sf_tui_rows 16 20
assert_equal '  exit 1' "$SF_PRESENT_ROW_TEXT[-1]"

sf_tui_reset
sf_tui_event tool_call call_long shell $'first row\nsecond row'
sf_tui_event tool_result call_long hidden done
sf_tui_rows 80 20
assert_equal $'⛭ shell\n│ first row\n│ …\n╰ done' \
  "${(F)SF_PRESENT_ROW_TEXT[-4,-1]}"

sf_tui_reset
sf_tui_event tool_call call_full edit_file path
sf_tui_event tool_result call_full hidden $'one\ntwo\nthree' file_diff full
sf_tui_rows 80 20
assert_equal $'⛭ edit_file\n│ path\n╰ one\n  two\n  three' \
  "${(F)SF_PRESENT_ROW_TEXT[-5,-1]}"

SF_PRESENT_STYLE[syntax.added]='fg=#010101,bg=#eeeeee'
SF_PRESENT_STYLE[syntax.removed]='fg=#020202,bg=#dddddd'
SF_PRESENT_HIGHLIGHT_ENABLED=1
sf_tui_reset
sf_tui_event tool_call call_diff edit_file path
sf_tui_event tool_result call_diff hidden $'-old\n+alpha beta' file_diff full
sf_tui_highlight_update
sf_tui_rows 12 20
assert_equal $'╰ -old      \n  +alpha    \n  beta      ' "${(F)SF_PRESENT_ROW_TEXT[-3,-1]}"
assert_equal '0 12 fg=#020202,bg=#dddddd' "$SF_PRESENT_ROW_HIGHLIGHTS[-3]"
assert_equal '0 12 fg=#010101,bg=#eeeeee' "$SF_PRESENT_ROW_HIGHLIGHTS[-2]"
assert_equal '0 12 fg=#010101,bg=#eeeeee' "$SF_PRESENT_ROW_HIGHLIGHTS[-1]"
SF_PRESENT_STYLE[syntax.added]=''
SF_PRESENT_STYLE[syntax.removed]=''
SF_PRESENT_HIGHLIGHT_ENABLED=0

sf_tui_reset
sf_tui_add notice notice 'Heads up' detail
sf_tui_add notice error Failed broken
sf_tui_rows 80 20
assert_equal $'ℹ Heads up\n  detail\n\n✕ Failed\n  broken' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_rows_config '{"tui":{"preview_lines_context":"full"}}'
sf_tui_reset
sf_tui_event context hook h 'alpha beta gamma'
sf_tui_rows 12 20
assert_equal $'↪ hook · h\n  alpha beta\n  gamma' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message user '' 'ab界c'
sf_tui_rows 4 20
assert_equal $'ab界\nc' "${(F)SF_PRESENT_ROW_TEXT}"
assert_equal '1:3,2:0' "${(j:,:)SF_PRESENT_ROW_CURSOR}"

sf_tui_reset
sf_tui_add message user '' $'e\u0301x'
sf_tui_rows 2 20
assert_equal $'e\u0301x' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message user '' $'abcd\u0301x'
sf_tui_rows 4 20
assert_equal $'abcd\u0301\nx' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message user '' $'a\tb'
sf_tui_rows 8 20
assert_equal $'a       \nb' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message user '' $'\tb'
sf_tui_rows 4 20
assert_equal $'    \nb' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message user '' 'comments are stripped after parsing'
sf_tui_rows 16 20
assert_equal $'comments are\nstripped after\nparsing' "${(F)SF_PRESENT_ROW_TEXT}"

# Syntax spans follow source characters through wrapping. The consumed space
# between rows has no display offset, while the semantic style remains first.
sf_tui_reset
SF_PRESENT_STYLE=( message.user fg=1 )
sf_tui_add message user '' 'hello world'
SF_PRESENT_HIGHLIGHT_CACHE[1]='3 9 fg=2'
sf_tui_rows 5 20
assert_equal '0 5 fg=1 3 5 fg=2' "$SF_PRESENT_ROW_HIGHLIGHTS[1]"
assert_equal '0 5 fg=1 0 3 fg=2' "$SF_PRESENT_ROW_HIGHLIGHTS[2]"

# A source tab maps to every space emitted for it, not to its source width.
sf_tui_reset
SF_PRESENT_STYLE=()
sf_tui_add message user '' $'a\tb'
SF_PRESENT_HIGHLIGHT_CACHE[1]='1 2 underline'
sf_tui_rows 8 20
assert_equal '1 8 underline' "$SF_PRESENT_ROW_HIGHLIGHTS[1]"
assert_equal '' "$SF_PRESENT_ROW_HIGHLIGHTS[2]"

# Decorated prefixes and trimmed leading newlines shift display and source in
# opposite directions.
sf_tui_reset
sf_tui_add reasoning agent '' $'\nabc'
SF_PRESENT_HIGHLIGHT_CACHE[1]='1 4 bold'
sf_tui_rows 80 20
assert_equal '2 5 bold' "$SF_PRESENT_ROW_HIGHLIGHTS[2]"

# Resuming after flushed source clips a span to the remaining display text.
sf_tui_reset
sf_tui_add message agent '' abcdef
SF_PRESENT_HIGHLIGHT_CACHE[1]='1 5 fg=3'
sf_tui_rows 80 20 1:3
assert_equal def "$SF_PRESENT_ROW_TEXT[1]"
assert_equal '0 2 fg=3' "$SF_PRESENT_ROW_HIGHLIGHTS[1]"

# ZLE offsets count characters rather than terminal cells. Wide and combining
# characters therefore retain one source/display offset each.
sf_tui_reset
sf_tui_add message user '' $'ab界e\u0301x'
SF_PRESENT_HIGHLIGHT_CACHE[1]='2 5 standout'
sf_tui_rows 80 20
assert_equal '2 5 standout' "$SF_PRESENT_ROW_HIGHLIGHTS[1]"

sf_tui_reset
sf_tui_add message user '' $'abcd\u0301x'
SF_PRESENT_HIGHLIGHT_CACHE[1]='3 5 underline'
sf_tui_rows 4 20
assert_equal '3 5 underline' "$SF_PRESENT_ROW_HIGHLIGHTS[1]"
assert_equal '' "$SF_PRESENT_ROW_HIGHLIGHTS[2]"

sf_tui_reset
sf_tui_add message user '' ' hello'
sf_tui_rows 3 20
assert_equal $' he\nllo' "${(F)SF_PRESENT_ROW_TEXT}"

sf_tui_reset
sf_tui_add message user '' $'abcd\nnext'
sf_tui_rows 4 20
assert_equal $'abcd\nnext' "${(F)SF_PRESENT_ROW_TEXT}"

if sf_tui_rows 0 1; then
  fail 'accepted a zero-width viewport'
fi
if sf_tui_rows 8 1 broken; then
  fail 'accepted an invalid cursor'
fi

# Semantic row styling resolves "type.role" before falling back to "type", and
# leaves blank separator rows unstyled.
SF_PRESENT_STYLE=( divider 'fg=8' section.user 'fg=1,bold' message 'fg=2'
  reasoning 'fg=3' tool_call 'fg=4' tool_result 'fg=4' injection 'fg=5' notice 'fg=6'
  clamp 'fg=7' muted 'fg=9' )
sf_tui_reset
sf_tui_event user hello
sf_tui_rows 8 20
assert_equal 'section.user,separator,message.user' "${(j:,:)SF_PRESENT_ROW_KIND}"
assert_equal '0 2 fg=8 2 7 fg=1,bold 7 8 fg=8||0 5 fg=2' \
  "${(j:|:)SF_PRESENT_ROW_HIGHLIGHTS}"

sf_tui_rows 20 20
assert_equal '─ user ───────── 1 ─' "$SF_PRESENT_ROW_TEXT[1]"
assert_equal '0 2 fg=8 2 7 fg=1,bold 7 20 fg=8 17 18 fg=9' "$SF_PRESENT_ROW_HIGHLIGHTS[1]"

sf_tui_event assistant reply
sf_tui_rows 20 20
integer agent_section=${SF_PRESENT_ROW_KIND[(i)section.agent]}
assert_equal '─ agent ──────── 2 ─' "$SF_PRESENT_ROW_TEXT[agent_section]"
assert_equal '0 2 fg=8 8 20 fg=8 17 18 fg=9' "$SF_PRESENT_ROW_HIGHLIGHTS[agent_section]"

sf_tui_reset
sf_tui_event user hello
sf_tui_rows 3 20
assert_equal '0 1 fg=8|0 3 fg=1,bold|0 2 fg=1,bold||0 3 fg=2|0 2 fg=2' \
  "${(j:|:)SF_PRESENT_ROW_HIGHLIGHTS}"

sf_tui_reset
sf_tui_event system hello
sf_tui_rows 80 20
assert_equal '0 5 fg=2' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_KIND[(i)message.system]}]"

sf_tui_reset
sf_tui_event assistant_reasoning_delta thinking
sf_tui_rows 20 20
assert_equal 'reasoning.agent' "$SF_PRESENT_ROW_KIND[3]"
assert_equal '0 11 fg=3' "$SF_PRESENT_ROW_HIGHLIGHTS[3]"

sf_tui_reset
sf_tui_event context hook project body
sf_tui_event tool_call call shell command unsandboxed
sf_tui_event tool_result call hidden result
sf_tui_add notice notice 'Heads up' detail
sf_tui_rows 80 20
assert_equal '0 16 fg=5 2 6 fg=5,bold' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_KIND[(i)injection.system]}]"
assert_equal '0 21 fg=4 2 7 fg=4,bold' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_KIND[(i)tool_call.agent]}]"
assert_equal '0 10 fg=6 2 10 fg=6,bold' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_KIND[(i)notice.notice]}]"
assert_equal '0 9 fg=4 0 1 fg=8' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_TEXT[(i)│ command]}]"
assert_equal '0 8 fg=4 0 1 fg=8' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_TEXT[(i)╰ result]}]"

sf_tui_reset
sf_tui_event tool_call active shell command
sf_tui_rows 80 20
assert_equal '0 3 fg=4 0 1 fg=8' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_TEXT[(i)╰ ⠃]}]"

SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_reset
sf_tui_event context 'hook name' project body
sf_tui_rows 80 20
assert_equal '↪ hook name · project · ~1 tokens' "$SF_PRESENT_ROW_TEXT[1]"
assert_equal '0 33 fg=5 2 11 fg=5,bold 22 33 fg=7' "$SF_PRESENT_ROW_HIGHLIGHTS[1]"
SF_PRESENT_PREVIEW_CONTEXT=1
sf_tui_reset
sf_tui_event context 'hook name' project "${(l:400::x:)}"
sf_tui_rows 80 20
assert_equal '0 15 fg=5 0 15 fg=7' "$SF_PRESENT_ROW_HIGHLIGHTS[-1]"
SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_reset
sf_tui_event system "${(l:1060::x:)}"
sf_tui_rows 80 20
assert_equal '… ~265 tokens' "$SF_PRESENT_ROW_TEXT[-1]"
assert_equal '0 13 fg=2 0 13 fg=7' "$SF_PRESENT_ROW_HIGHLIGHTS[-1]"
SF_PRESENT_PREVIEW_CONTEXT=full

SF_PRESENT_PREVIEW_TOOL_RESULT=full
sf_tui_reset
sf_tui_event tool_call status shell body
sf_tui_event tool_result status 1 result
sf_tui_rows 80 20
assert_equal '  exit 1' "$SF_PRESENT_ROW_TEXT[-1]"
assert_equal '0 8 fg=4' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[-1]"

sf_tui_reset
sf_tui_event tool_call wrapped very_long_tool_name body
sf_tui_event tool_result wrapped hidden result
sf_tui_add notice notice 'Long notice heading' detail
sf_tui_rows 8 20
assert_equal '0 8 fg=4 0 8 fg=4,bold' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_TEXT[(i)very_lon]}]"
assert_equal '0 6 fg=6 0 6 fg=6,bold' \
  "$SF_PRESENT_ROW_HIGHLIGHTS[${SF_PRESENT_ROW_TEXT[(i)notice]}]"

# An unstyled kind produces no span, and every row keeps a highlight slot.
SF_PRESENT_STYLE=()
sf_tui_reset
sf_tui_event user hello
sf_tui_rows 8 20
assert_equal '||' "${(j:|:)SF_PRESENT_ROW_HIGHLIGHTS}"
assert_equal "${#SF_PRESENT_ROW_TEXT}" "${#SF_PRESENT_ROW_HIGHLIGHTS}"
