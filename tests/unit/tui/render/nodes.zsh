#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/nodes.zsh libexec/tui/render/highlights.zsh

sf_tui_event user hello
sf_tui_event user again
sf_tui_event assistant_delta 'part '
sf_tui_event assistant_delta done
sf_tui_event assistant_commit

assert_equal 'section,message,message,section,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal 'user,user,user,agent,agent' "${(j:,:)SF_PRESENT_NODE_ROLE}"
assert_equal 'part done' "$SF_PRESENT_NODE_BODY[5]"
assert_equal closed "$SF_PRESENT_NODE_STATE[5]"

sf_tui_reset
sf_tui_add message agent '' $'first\nsecond' open
sf_tui_set_frontier 1 6
assert_equal 6 "$SF_PRESENT_NODE_FRONTIER[1]"
if sf_tui_set_frontier 1 5; then
  fail 'moved a node frontier backward'
fi
sf_tui_close 1
assert_equal 6 "$SF_PRESENT_NODE_FRONTIER[1]"

sf_tui_reset
sf_tui_event assistant_reasoning_delta thought
sf_tui_event reasoning_tokens 7
sf_tui_event assistant_delta answer
assert_equal 'section,reasoning,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal closed "$SF_PRESENT_NODE_STATE[2]"
assert_equal 7 "$SF_PRESENT_NODE_META[2]"
assert_equal open "$SF_PRESENT_NODE_STATE[3]"

sf_tui_event assistant_commit
sf_tui_event tool_call call_1 shell '{"command":"true"}'
sf_tui_event tool_call call_2 read_file README.md '' plain
sf_tui_event tool_permission 'host access'
assert_equal 1 "$REPLY"
assert_equal permission "$SF_PRESENT_NODE_STATUS[5]"
assert_equal 'host access' "$SF_PRESENT_NODE_BODY[5]"
sf_tui_event tool_permission_clear
assert_equal '' "$SF_PRESENT_NODE_STATUS[5]"
assert_equal '' "$SF_PRESENT_NODE_BODY[5]"
sf_tui_event tool_result call_1 0 ok
assert_equal tool_call "$SF_PRESENT_NODE_TYPE[4]"
assert_equal shell "$SF_PRESENT_NODE_HEADING[4]"
assert_equal json "$SF_PRESENT_NODE_FORMAT[4]"
assert_equal tool_result "$SF_PRESENT_NODE_TYPE[5]"
assert_equal ok "$SF_PRESENT_NODE_BODY[5]"
assert_equal 0 "$SF_PRESENT_NODE_STATUS[5]"
assert_equal closed "$SF_PRESENT_NODE_STATE[5]"
sf_tui_event tool_result call_2 0 contents
assert_equal tool_call "$SF_PRESENT_NODE_TYPE[6]"
assert_equal plain "$SF_PRESENT_NODE_FORMAT[6]"
assert_equal tool_result "$SF_PRESENT_NODE_TYPE[7]"

sf_tui_reset
sf_tui_event context project_environment session_start '<env>test</env>'
sf_tui_event user ''
assert_equal 'injection,section,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal session_start "$SF_PRESENT_NODE_META[1]"
assert_equal project_environment "$SF_PRESENT_NODE_HEADING[1]"
assert_equal '' "$SF_PRESENT_NODE_BODY[3]"

sf_tui_reset
sf_tui_event user hello
sf_tui_event context hook prompt injected
sf_tui_event user again
assert_equal 'section,message,injection,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"

sf_tui_reset
sf_tui_event assistant ''
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"

sf_tui_event assistant $'\n\n' $'\n'
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"

sf_tui_event backend_request_start
sf_tui_event assistant_delta $'\n'
sf_tui_event assistant_reasoning_delta $'\n\n'
assert_equal 'section,reasoning' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal $'\n\n' "$SF_PRESENT_NODE_BODY[2]"
sf_tui_event assistant_commit
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"
assert_equal 0 "$SF_PRESENT_SECTION_ID"

sf_tui_event assistant_delta $'answer\n'
sf_tui_event assistant_delta $'\n'
sf_tui_set_frontier 2 8
sf_tui_event assistant_commit
assert_equal $'answer\n\n' "$SF_PRESENT_NODE_BODY[2]"
assert_equal 8 "$SF_PRESENT_NODE_FRONTIER[2]"

sf_tui_event assistant_delta $'\nnext'
sf_tui_event assistant_commit
assert_equal $'\nnext' "$SF_PRESENT_NODE_BODY[3]"

sf_tui_event backend_request_start
sf_tui_event assistant_delta $'\n'
sf_tui_event assistant_commit
assert_equal 'section,message,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"

sf_tui_reset
sf_tui_event user hello
sf_tui_event backend_request_start
sf_tui_event assistant_commit
sf_tui_event user again
assert_equal 'section,message,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal 1 "$SF_PRESENT_SECTION_ID"

sf_tui_reset
sf_tui_add reasoning agent '' '' open
sf_tui_close 1
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"

sf_tui_add reasoning agent '' $'thought\n\n' open
sf_tui_set_frontier 1 9
sf_tui_close 1
assert_equal $'thought\n\n' "$SF_PRESENT_NODE_BODY[1]"
assert_equal 9 "$SF_PRESENT_NODE_FRONTIER[1]"

sf_tui_reset
sf_tui_event user hello
sf_tui_drop 2
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"
sf_tui_section user
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"
sf_tui_section agent
assert_equal section "$SF_PRESENT_NODE_TYPE[1]"

sf_tui_reset
sf_tui_event user $'\n\n  unsafe\e[31m\t\n'
sf_tui_event assistant_delta $'\n\treply\rtext\n\n'
sf_tui_event assistant_commit
assert_equal $'\n\n  unsafe�[31m\t\n' "$SF_PRESENT_NODE_BODY[2]"
assert_equal $'\n\treply�text\n\n' "$SF_PRESENT_NODE_BODY[4]"

sf_tui_reset
sf_tui_add activity '' '' '' open
sf_tui_event assistant_reasoning_delta thought
assert_equal 'section,reasoning' "${(j:,:)SF_PRESENT_NODE_TYPE}"

sf_tui_reset
sf_tui_add activity '' '' '' open
sf_tui_event backend_request_start
assert_equal 'section,activity' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal 'agent,agent' "${(j:,:)SF_PRESENT_NODE_ROLE}"
assert_equal open "$SF_PRESENT_NODE_STATE[-1]"
sf_tui_event assistant_delta answer
assert_equal 'section,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"

sf_tui_reset
sf_tui_section agent
sf_tui_add tool_result agent shell result
sf_tui_event backend_request_start
assert_equal 'section,tool_result,activity' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal agent "$SF_PRESENT_NODE_ROLE[-1]"

sf_tui_reset
sf_tui_add activity '' '' '' open
sf_tui_event assistant_delta answer
assert_equal 'section,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"

sf_tui_reset
sf_tui_add activity '' '' '' open
sf_tui_event assistant_commit
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"

sf_tui_reset
sf_tui_add message agent '' '' open
if sf_tui_add notice '' error failed; then
  fail 'accepted a node after an open tail'
fi

sf_tui_reset
sf_tui_add notice '' working '' open
if sf_tui_event assistant_commit; then
  fail 'closed a non-assistant node on assistant commit'
fi

sf_test_tmp presentation
sf_tui_reload "$SF_TEST_SESSIONS/tool-paired.jsonl" || fail "$SF_PRESENT_ERROR"
assert_equal 'section,message,section,tool_call,tool_result,tool_call,tool_result,message,injection' \
  "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal 'Use both tools' "$SF_PRESENT_NODE_BODY[2]"
assert_equal Done "$SF_PRESENT_NODE_BODY[8]"

# Replay initializes the frozen runtime from the durable header and clears any
# usage the previous session left in the footer.
SF_PRESENT_IDENTITY=stale/model
SF_PRESENT_FOOTER='stale/model · stale usage'
sf_tui_reload "$SF_TEST_SESSIONS/header-only.jsonl" || fail "$SF_PRESENT_ERROR"
assert_equal test/fake-model "$SF_PRESENT_FOOTER"
assert_equal fake-model "$(jq -r '.profile.request.model' <<<"$SF_PRESENT_RUNTIME")"

cp "$SF_TEST_SESSIONS/tool-paired.jsonl" "$tmp/invalid.jsonl"
print -r -- broken >>"$tmp/invalid.jsonl"
if sf_tui_reload "$tmp/invalid.jsonl"; then
  fail 'accepted an invalid durable transcript'
fi

# Replay is now the only source of the runtime, so a malformed header leaves the
# client nothing to present.
jq -c 'del(.backend)' "$SF_TEST_SESSIONS/header-only.jsonl" >"$tmp/bad-header.jsonl"
if sf_tui_reload "$tmp/bad-header.jsonl"; then
  fail 'accepted a malformed session header'
fi

# Theme resolution supplies both chrome and semantic syntax styles, and stays
# inert when the environment refuses color.
unset NO_COLOR
TERM=xterm-256color
typeset -g theme_config='{"theme":{"mode":"dark","light":{"name":"l","palette":{
  "muted":"#111111","divider":"#111111","footer":"#111111",
    "prompt":"#111111","system_heading":"#111111","context":"#111111",
    "user_heading":"#111111","agent_heading":"#111111","tool":"#111111",
    "reasoning":"#111111","error":"#111111","diff_added":"#111111",
    "syntax_comment":"#111112","syntax_keyword":"#111113",
    "syntax_string":"#111114","syntax_number":"#111115",
    "syntax_tag":"#111116",
    "diff_added_background":"#111111","diff_removed":"#111111",
    "diff_removed_background":"#111111","permission":"#111111"}},
  "dark":{"name":"d","palette":{"text":"#777777","muted":"#222222","divider":"#333333","footer":"#222222",
    "prompt":"#444444","system_heading":"#222222","context":"#222222",
    "user_heading":"#555555","agent_heading":"#222222","tool":"#222222",
    "reasoning":"#222222","error":"#666666","diff_added":"#222222",
    "syntax_comment":"#222223","syntax_keyword":"#222224",
    "syntax_string":"#222225","syntax_number":"#222226",
    "syntax_tag":"#222227",
    "diff_added_background":"#222222","diff_removed":"#222222",
    "diff_removed_background":"#222222","permission":"#222222"}}}}'

sf_tui_theme_config "$theme_config" || fail "theme setup failed: $SF_PRESENT_HIGHLIGHT_ERROR"
assert_equal 'fg=#555555,bold' "$SF_PRESENT_STYLE[section.user]"
assert_equal 'fg=#777777' "$SF_PRESENT_STYLE[message]"
assert_equal 'fg=#333333' "$SF_PRESENT_STYLE[divider]"
assert_equal 'fg=#222222' "$SF_PRESENT_STYLE[clamp]"
assert_equal 'fg=#666666' "$SF_PRESENT_STYLE[notice.error]"
assert_equal 'fg=#444444' "$SF_PRESENT_STYLE[prompt]"
assert_equal 'fg=#222222' "$SF_PRESENT_STYLE[permission.divider]"
assert_equal 'fg=#222225' "$SF_PRESENT_STYLE[syntax.string]"
assert_equal 'fg=#222223' "$SF_PRESENT_STYLE[syntax.comment]"
assert_equal 'fg=#222224' "$SF_PRESENT_STYLE[syntax.keyword]"
assert_equal 'fg=#222226' "$SF_PRESENT_STYLE[syntax.number]"
assert_equal 'fg=#222227' "$SF_PRESENT_STYLE[syntax.tag]"
assert_equal 'fg=#222222' "$SF_PRESENT_STYLE[syntax.fence]"
assert_equal 'fg=#222222' "$SF_PRESENT_STYLE[syntax.table]"

if NO_COLOR=1 sf_tui_theme_config "$theme_config"; then
  assert_equal 0 "${#SF_PRESENT_STYLE}"
else
  fail 'NO_COLOR should disable styling rather than fail'
fi
if TERM=dumb sf_tui_theme_config "$theme_config"; then
  assert_equal 0 "${#SF_PRESENT_STYLE}"
else
  fail 'a dumb terminal should disable styling rather than fail'
fi

# theme.mode:auto resolves through the background probe, caches the answer for
# the process, and falls back to dark when the terminal does not reply.
typeset -g auto_config=${theme_config/'"mode":"dark"'/'"mode":"auto"'}
[[ $auto_config == *'"mode":"auto"'* ]] || fail 'auto theme fixture was not built'
typeset -gi probe_calls=0
sf_tui_background_mode() { (( ++probe_calls )); REPLY=light; }

SF_PRESENT_BACKGROUND=''
sf_tui_theme_config "$auto_config" || fail "auto theme setup failed: $SF_PRESENT_HIGHLIGHT_ERROR"
assert_equal light "$SF_PRESENT_BACKGROUND"
assert_equal 'fg=#111111,bold' "$SF_PRESENT_STYLE[section.user]"
assert_equal '' "$SF_PRESENT_STYLE[message]"
assert_equal 1 "$probe_calls"

sf_tui_theme_config "$auto_config" || fail 'a cached background was rejected'
assert_equal 1 "$probe_calls"

SF_PRESENT_BACKGROUND=''
sf_tui_background_mode() { return 1 }
sf_tui_theme_config "$auto_config" || fail 'an unanswered probe should fall back to dark'
assert_equal dark "$SF_PRESENT_BACKGROUND"

# Native spans are cached while the unfinished trailing line stays behind the
# stable frontier.
sf_tui_theme_config "$theme_config" || fail "theme setup failed: $SF_PRESENT_HIGHLIGHT_ERROR"
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_ENABLED"

span_texts() {
  local source=$1
  local -a texts=()
  integer index start end
  for (( index = 1; index <= ${#SF_PRESENT_HIGHLIGHT_SPANS}; index += 3 )); do
    start=$(( SF_PRESENT_HIGHLIGHT_SPANS[index] + 1 ))
    end=${SF_PRESENT_HIGHLIGHT_SPANS[index + 1]}
    texts+=( "${source[start,end]}" )
  done
  REPLY="${(j:,:)texts}"
}

# Common languages share semantic token kinds and keep character offsets before
# multibyte source text. Unknown languages remain plain.
typeset code='é const x = "text"; // note'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight "$code" js
span_texts "$code"
assert_equal 'const,"text",// note' "$REPLY"
assert_equal '2,7,fg=#222224' "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[1,3]}"

SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'true: 12 # note' yaml
span_texts 'true: 12 # note'
assert_equal 'true,12,# note' "$REPLY"
assert_equal '0,4,fg=#222227' "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[1,3]}"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight $'parent:\n  child-key: value\n# not: a key' yaml
span_texts $'parent:\n  child-key: value\n# not: a key'
assert_equal 'parent,child-key,# not: a key' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'interface User { readonly name: string; }' typescript
span_texts 'interface User { readonly name: string; }'
assert_equal 'interface,readonly,string' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight $'def greet():\n    """First line\n    second line."""\n    return 1' python
span_texts $'def greet():\n    """First line\n    second line."""\n    return 1'
assert_equal $'def,"""First line\n    second line.""",return,1' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight '<main id="content">' html
span_texts '<main id="content">'
assert_equal '<main,"content",>' "$REPLY"
assert_equal '0,5,fg=#222227' "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[1,3]}"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight '<item name="a > b" />' html
span_texts '<item name="a > b" />'
assert_equal '<item,"a > b",/>' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight '</item>' xml
span_texts '</item>'
assert_equal '</item>' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight anything rust
assert_equal 0 "${#SF_PRESENT_HIGHLIGHT_SPANS}"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'value * other * last' js
assert_equal 0 "${#SF_PRESENT_HIGHLIGHT_SPANS}"

typeset shell_code='find . -type f | grep --extended-regexp "foo --bar" # tail -n'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight "$shell_code" sh
span_texts "$shell_code"
assert_equal 'find,-type,grep,--extended-regexp,"foo --bar",# tail -n' "$REPLY"
assert_equal '0,4,fg=#222224' "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[1,3]}"
assert_equal '7,12,fg=#222227' "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[4,6]}"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'echo foo-bar -1 --color=auto' bash
span_texts 'echo foo-bar -1 --color=auto'
assert_equal 'echo,1,--color' "$REPLY"

typeset markdown=$'# Head\n**bold** [link](url) `code`\n```js\nconst x = 3;\n```'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight "$markdown"
span_texts "$markdown"
assert_equal $'# Head,**bold**,[link](url),`code`,```js,const,3,```' "$REPLY"
assert_equal '0,6,bold,underline,7,15,bold' \
  "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[1,6]}"

# Table punctuation stays in the source but is muted. Inline constructs keep
# their own styles, and neither escaped nor inline-code pipes become separators.
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '| Name | Status |'
span_texts '| Name | Status |'
assert_equal '|,|,|' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '| --- | :---: |'
span_texts '| --- | :---: |'
assert_equal '| --- | :---: |' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
markdown='| **A** | `x | y` | a\|b |'
sf_tui_markdown_highlight "$markdown"
span_texts "$markdown"
assert_equal '|,**A**,|,`x | y`,|,|' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight 'value | other'
assert_equal 0 "${#SF_PRESENT_HIGHLIGHT_SPANS}"
sf_tui_markdown_highlight '| first | long cell '
assert_equal table "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight 'continued | last' 0 table 1
span_texts 'continued | last'
assert_equal '|' "$REPLY"
sf_tui_markdown_highlight $'continued | last\n' 0 table 1
assert_equal '' "$REPLY"

SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '- item'
span_texts '- item'
assert_equal '' "$REPLY"

markdown=$'```js\n\nconst value\n\t```'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight "$markdown"
span_texts "$markdown"
assert_equal $'```js,const,\t```' "$REPLY"

# A continuation fragment is not a line, so line-leading syntax stays plain and
# the block mode it inherited still applies.
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '- not a list marker' 0 '' 1
assert_equal 0 "${#SF_PRESENT_HIGHLIGHT_SPANS}"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '# not a heading' 0 '' 0
(( ${#SF_PRESENT_HIGHLIGHT_SPANS} )) || fail 'a real line start lost its heading style'
typeset -a heading_spans
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '  # Heading'
heading_spans=( "${SF_PRESENT_HIGHLIGHT_SPANS[@]}" )
assert_equal heading "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight $' continues\n' 11 heading 1
heading_spans+=( "${SF_PRESENT_HIGHLIGHT_SPANS[@]}" )
assert_equal '2 11 bold,underline 11 21 bold,underline' "${(j: :)heading_spans}"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight 'const x = 3;' 0 $'```\tjs' 1
span_texts 'const x = 3;'
assert_equal 'const,3' "$REPLY"
# A closing fence is a whole line, so a fragment that resembles one leaves the
# block mode open where a real line start would close it.
sf_tui_markdown_highlight '```' 0 $'```\tjs\t0' 1
assert_equal $'```\tjs\t0' "$REPLY"
sf_tui_markdown_highlight $'```\n' 0 $'```\tjs\t0' 0
assert_equal '' "$REPLY"

# An unclosed inline construct is reported so a caller can withhold the row; a
# block mode is carried in the state instead and never reports open.
sf_tui_markdown_highlight 'a **bold start'
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
sf_tui_markdown_highlight 'a **bold start** done'
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
sf_tui_markdown_highlight 'a `code start'
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
# A newline closes the question, whatever the line left dangling.
sf_tui_markdown_highlight $'a **bold start\n'
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
# Multiplication is not emphasis: a delimiter followed by a space cannot open.
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight 'value * other * last'
assert_equal 0 "${#SF_PRESENT_HIGHLIGHT_SPANS}"
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
# Emphasis and strong tags require outer word boundaries.
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight 'plain_old_text and plain**old**text'
assert_equal 0 "${#SF_PRESENT_HIGHLIGHT_SPANS}"
sf_tui_markdown_highlight 'plain_old_text_ and plain**old**'
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '_also_plain_text_ and **bold**'
span_texts '_also_plain_text_ and **bold**'
assert_equal '_also_plain_text_,**bold**' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight '_assistant_response_end and _italic_'
span_texts '_assistant_response_end and _italic_'
assert_equal _italic_ "$REPLY"
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
sf_tui_markdown_highlight $'```js\nconst x = 3;'
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
assert_equal $'```\tjs\t0' "$REPLY"

# A block comment is a mode, not a wait: it carries across the boundary that
# interrupted it and keeps styling until something closes it.
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight '/* opened' js
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_BLOCK_OPEN"
span_texts '/* opened'
assert_equal '/* opened' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'still inside */ const x = 3;' js 0 1
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_BLOCK_OPEN"
span_texts 'still inside */ const x = 3;'
assert_equal 'still inside */,const,3' "$REPLY"

SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight '"""opened' python
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_BLOCK_OPEN"
span_texts '"""opened'
assert_equal '"""opened' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'still inside""" return 1' python 0 1
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_BLOCK_OPEN"
span_texts 'still inside""" return 1'
assert_equal 'still inside""",return,1' "$REPLY"
# An open block never reports as an open inline construct, so it never waits.
sf_tui_markdown_highlight $'```js\n/* opened\n'
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_INLINE_OPEN"
assert_equal $'```\tjs\t1' "$REPLY"
sf_tui_markdown_highlight $'closed */\n' 0 $'```\tjs\t1' 0
assert_equal $'```\tjs\t0' "$REPLY"

typeset diff=$'@@ -1 +1 @@\n-old\n+new\n--- a/file\n+++ b/file'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_diff_highlight "$diff"
span_texts "$diff"
assert_equal '-old,+new' "$REPLY"

sf_tui_reset
sf_tui_add message agent '' $'**bold** text\nsecond line' open
sf_tui_highlight_update
(( ${#SF_PRESENT_HIGHLIGHT_CACHE[1]} )) || fail 'no cached spans for a markdown body'
assert_equal markdown "$SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[1]"
assert_equal 14 "$SF_PRESENT_NODE_FRONTIER[1]"

sf_tui_reset
sf_tui_add message agent '' $'```js\n' open
sf_tui_highlight_update
sf_tui_append 1 $'const first = 1;\n'
sf_tui_highlight_update
sf_tui_append 1 $'const second = 2;\n```\n'
sf_tui_highlight_update
typeset incremental_spans=$SF_PRESENT_HIGHLIGHT_CACHE[1]
assert_equal '' "$SF_PRESENT_HIGHLIGHT_CACHE_STATE[1]"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight "$SF_PRESENT_NODE_BODY[1]"
assert_equal "${(j: :)SF_PRESENT_HIGHLIGHT_SPANS}" "$incremental_spans"

typeset -gi highlight_calls=0
functions[sf_tui_markdown_original]=$functions[sf_tui_markdown_highlight]
sf_tui_markdown_highlight() {
  (( ++highlight_calls ))
  sf_tui_markdown_original "$@"
}

sf_tui_reset
sf_tui_add message agent '' $'line one\nline two continues' open
sf_tui_highlight_update
assert_equal 9 "$SF_PRESENT_NODE_FRONTIER[1]"

# An unfinished line remains mutable regardless of its length.
sf_tui_reset
sf_tui_add message agent '' "a"$'\n'"${(l:50::x:)""}" open
sf_tui_highlight_update
assert_equal 2 "$SF_PRESENT_NODE_FRONTIER[1]"

# A short line with no newline yet has nothing safe to settle.
highlight_calls=0
sf_tui_reset
sf_tui_add message agent '' hello open
sf_tui_highlight_update
assert_equal 0 "$SF_PRESENT_NODE_FRONTIER[1]"
assert_equal 0 "$highlight_calls"
sf_tui_append 1 ' world'
sf_tui_highlight_update
assert_equal 0 "$highlight_calls"
sf_tui_append 1 $'\n'
sf_tui_highlight_update
assert_equal 1 "$highlight_calls"

# Closing settles the rest of the body, scanning only what the frontier had
# left: the completed lines behind it are never revisited.
sf_tui_reset
sf_tui_add message agent '' $'closed\nbody' open
sf_tui_highlight_update
assert_equal 7 "$SF_PRESENT_NODE_FRONTIER[1]"
highlight_calls=0
sf_tui_close 1
assert_equal 7 "$SF_PRESENT_NODE_FRONTIER[1]"
sf_tui_highlight_update
assert_equal 11 "$SF_PRESENT_NODE_FRONTIER[1]"
assert_equal 1 "$highlight_calls"

# An unchanged body reuses its cached spans instead of re-running the tokenizer.
highlight_calls=0
sf_tui_highlight_update
assert_equal 0 "$highlight_calls"

functions[sf_tui_markdown_highlight]=$functions[sf_tui_markdown_original]
unfunction sf_tui_markdown_original

# Cache entries follow the nodes they describe when the front is pruned.
sf_tui_reset
sf_tui_add message agent '' first
sf_tui_add message agent '' second
sf_tui_highlight_update
assert_equal 2 "${#SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE}"
sf_tui_drop 1
assert_equal 1 "${#SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE}"
assert_equal 6 "$SF_PRESENT_NODE_FRONTIER[1]"

# Node metadata selects syntax modes without interpreting display content.
sf_tui_reset
sf_tui_add tool_call agent shell '{"command":"true"}'
SF_PRESENT_NODE_FORMAT[REPLY]=json
sf_tui_add tool_call agent shell 'if true; then print yes; fi'
SF_PRESENT_NODE_FORMAT[REPLY]=sh
sf_tui_add tool_call agent edit_file notes.txt
SF_PRESENT_NODE_FORMAT[REPLY]=plain
sf_tui_add tool_result agent '' $'@@ -1 +1 @@\n-old\n+new'
SF_PRESENT_NODE_FORMAT[REPLY]=file_diff
sf_tui_add tool_result agent '' '**output**'
SF_PRESENT_NODE_FORMAT[REPLY]=md
sf_tui_add tool_result agent '' output
sf_tui_highlight_update
[[ -n $SF_PRESENT_HIGHLIGHT_CACHE[1] ]] || fail 'JSON tool call was not highlighted'
[[ -n $SF_PRESENT_HIGHLIGHT_CACHE[2] ]] || fail 'shell tool call was not highlighted'
[[ -n $SF_PRESENT_HIGHLIGHT_CACHE[4] ]] || fail 'diff tool result was not highlighted'
[[ -n $SF_PRESENT_HIGHLIGHT_CACHE[5] ]] || fail 'Markdown tool result was not highlighted'
assert_equal plain "$SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[3]"
assert_equal plain "$SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[6]"

# Pruning drops what scrolled away, and a later scan appends beyond it using
# absolute source offsets rather than restarting from zero.
sf_tui_reset
sf_tui_add message agent '' $'**abcdef**\n' open
sf_tui_highlight_update
sf_tui_highlight_prune 1 3
assert_equal 3 "$SF_PRESENT_HIGHLIGHT_CACHE_START[1]"
typeset -a pruned=( ${(s: :)SF_PRESENT_HIGHLIGHT_CACHE[1]} )
(( pruned[1] >= 3 )) || fail 'kept a syntax span before the retained offset'
sf_tui_append 1 $'**ij**\n'
sf_tui_highlight_update
pruned=( ${(s: :)SF_PRESENT_HIGHLIGHT_CACHE[1]} )
(( pruned[1] >= 3 )) || fail 'restored a syntax span before the retained offset'
(( pruned[-2] > 11 )) || fail 'a later scan did not use absolute offsets'

# A node that scans nothing keeps its own empty block mode rather than adopting
# whatever the node before it left open.
sf_tui_reset
sf_tui_add message agent '' $'```js\n'
sf_tui_add message agent '' '' open
sf_tui_highlight_update
assert_equal $'```\tjs\t0' "$SF_PRESENT_HIGHLIGHT_CACHE_STATE[1]"
assert_equal '' "$SF_PRESENT_HIGHLIGHT_CACHE_STATE[2]"

# A released row boundary sits inside an unfinished line. Later highlights and
# resizes must not retreat it.
SF_PRESENT_HIGHLIGHT_ENABLED=1
sf_tui_reset
sf_tui_add message agent '' "${(l:60::x:)""}" open
sf_tui_highlight_update
assert_equal 0 "$SF_PRESENT_NODE_FRONTIER[1]"
sf_tui_set_frontier 1 40
sf_tui_append 1 y
sf_tui_highlight_update || fail 'a later highlight retreated the frontier'
assert_equal 40 "$SF_PRESENT_NODE_FRONTIER[1]"
