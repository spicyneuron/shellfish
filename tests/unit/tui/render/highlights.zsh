#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/highlights.zsh

# Theme resolution covers chrome and syntax styles.
unset NO_COLOR
TERM=xterm-256color
typeset -g theme_config='{"theme":{"mode":"dark","light":{"name":"l","palette":{
  "muted":"#111111","divider":"#111111","footer":"#111111",
    "prompt":"#111111","prompt_waiting":"#111111","system_heading":"#111111","context":"#111111",
    "user_heading":"#111111","agent_heading":"#111111","tool":"#111111",
    "reasoning":"#111111","error":"#111111","diff_added":"#111111",
    "syntax_comment":"#111112","syntax_keyword":"#111113",
    "syntax_string":"#111114","syntax_number":"#111115",
    "syntax_tag":"#111116",
    "diff_added_background":"#111111","diff_removed":"#111111",
    "diff_removed_background":"#111111","permission":"#111111"}},
  "dark":{"name":"d","palette":{"text":"#777777","muted":"#222222","divider":"#333333","footer":"#222222",
    "prompt":"#444444","prompt_waiting":"#448844","system_heading":"#222222","context":"#222222",
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
assert_equal 'fg=#666666' "$SF_PRESENT_STYLE[error]"
assert_equal 'fg=#444444' "$SF_PRESENT_STYLE[prompt]"
assert_equal 'fg=#448844' "$SF_PRESENT_STYLE[prompt_waiting]"
assert_equal 'fg=#222225' "$SF_PRESENT_STYLE[syntax.string]"

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

# Auto mode uses the detected background and defaults to dark.
typeset -g auto_config=${theme_config/'"mode":"dark"'/'"mode":"auto"'}
[[ $auto_config == *'"mode":"auto"'* ]] || fail 'auto theme fixture was not built'
sf_tui_background_mode() { REPLY=light; }

SF_PRESENT_BACKGROUND=''
sf_tui_theme_config "$auto_config" || fail "auto theme setup failed: $SF_PRESENT_HIGHLIGHT_ERROR"
assert_equal light "$SF_PRESENT_BACKGROUND"
assert_equal 'fg=#111111,bold' "$SF_PRESENT_STYLE[section.user]"
assert_equal '' "$SF_PRESENT_STYLE[message]"

SF_PRESENT_BACKGROUND=''
sf_tui_background_mode() { return 1 }
sf_tui_theme_config "$auto_config" || fail 'an unanswered probe should fall back to dark'
assert_equal dark "$SF_PRESENT_BACKGROUND"

sf_tui_theme_config "$theme_config" || fail "theme setup failed: $SF_PRESENT_HIGHLIGHT_ERROR"

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

# Syntax offsets count characters before multibyte text.
typeset code='é const x = "text"; // note'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight "$code" js
span_texts "$code"
assert_equal 'const,"text",// note' "$REPLY"
assert_equal '2,7,fg=#222224' "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[1,3]}"

typeset markdown=$'# Head\n**bold** [link](url) `code`\n```js\nconst x = 3;\n```'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight "$markdown"
span_texts "$markdown"
assert_equal $'# Head,**bold**,[link](url),`code`,```js,const,3,```' "$REPLY"
assert_equal '0,6,bold,underline,7,15,bold' \
  "${(j:,:)SF_PRESENT_HIGHLIGHT_SPANS[1,6]}"

markdown=$'```js\n\nconst value\n\t```'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight "$markdown"
span_texts "$markdown"
assert_equal $'```js,const,\t```' "$REPLY"

SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight 'const x = 3;' 0 $'```\tjs' 1
span_texts 'const x = 3;'
assert_equal 'const,3' "$REPLY"
sf_tui_markdown_highlight $'```\n' 0 $'```\tjs\t0' 0
assert_equal '' "$REPLY"

sf_tui_markdown_highlight $'```js\nconst x = 3;'
assert_equal $'```\tjs\t0' "$REPLY"

# Block comments carry styling state across chunks.
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight '/* opened' js
span_texts '/* opened'
assert_equal '/* opened' "$REPLY"
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'still inside */ const x = 3;' js 0 1
span_texts 'still inside */ const x = 3;'
assert_equal 'still inside */,const,3' "$REPLY"

# Open blocks do not wait.
sf_tui_markdown_highlight $'```js\n/* opened\n'
assert_equal $'```\tjs\t1' "$REPLY"
sf_tui_markdown_highlight $'closed */\n' 0 $'```\tjs\t1' 0
assert_equal $'```\tjs\t0' "$REPLY"

typeset diff=$'@@ -1 +1 @@\n-old\n+new\n--- a/file\n+++ b/file'
SF_PRESENT_HIGHLIGHT_SPANS=()
sf_tui_diff_highlight "$diff"
span_texts "$diff"
assert_equal '-old,+new' "$REPLY"
