#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/highlights.zsh

# Theme resolution covers chrome and syntax styles.
unset NO_COLOR
TERM=xterm-256color
typeset -g theme_config='{"theme_mode":"dark","theme_light":"l","theme_dark":"d",
  "themes":{"l":{
  "muted":"#111111","divider":"#111111","footer":"#111111",
    "prompt":"#111111","prompt_waiting":"#111111","system":"#111111",
    "user":"#111111","agent":"#111111","activity":"#111111","link":"#111111","code":"#111111","tool":"#111111",
    "reasoning":"#111111","error":"#111111","diff_added":"#111111",
    "syntax_comment":"#111112","syntax_keyword":"#111113",
    "syntax_string":"#111114","syntax_number":"#111115",
    "syntax_tag":"#111116",
    "diff_added_background":"#111111","diff_removed":"#111111",
    "diff_removed_background":"#111111","permission":"#111111"},
  "d":{"text":"#777777","muted":"#222222","divider":"#333333","footer":"#222222",
    "prompt":"#444444","prompt_waiting":"#448844","system":"#232323",
    "user":"#555555","agent":"#2a2a2a","activity":"#2b2b2b","link":"#565656","code":"#575757","tool":"#222222",
    "reasoning":"#222222","error":"#666666","diff_added":"#222222",
    "syntax_comment":"#222223","syntax_keyword":"#222224",
    "syntax_string":"#222225","syntax_number":"#222226",
    "syntax_tag":"#222227",
    "diff_added_background":"#222222","diff_removed":"#222222",
    "diff_removed_background":"#222222","permission":"#222222"}}}'

sf_tui_theme_config "$theme_config" || fail "theme setup failed: $SF_TUI_HIGHLIGHT_ERROR"
assert_equal 'fg=#555555,bold' "$SF_TUI_STYLE[section.user]"
assert_equal 'fg=#2a2a2a,bold' "$SF_TUI_STYLE[section.agent]"
assert_equal 'fg=#232323,bold' "$SF_TUI_STYLE[section.system]"
assert_equal 'fg=#2b2b2b' "$SF_TUI_STYLE[activity]"
assert_equal 'fg=#565656,underline' "$SF_TUI_STYLE[syntax.link]"
assert_equal 'fg=#575757' "$SF_TUI_STYLE[syntax.code]"
assert_equal 'fg=#222222' "$SF_TUI_STYLE[execution]"
assert_equal 'fg=#777777' "$SF_TUI_STYLE[message]"
assert_equal 'fg=#666666' "$SF_TUI_STYLE[error]"
assert_equal 'fg=#444444' "$SF_TUI_STYLE[prompt]"
assert_equal 'fg=#448844' "$SF_TUI_STYLE[prompt_waiting]"
assert_equal 'fg=#222225' "$SF_TUI_STYLE[syntax.string]"

if NO_COLOR=1 sf_tui_theme_config "$theme_config"; then
  assert_equal 0 "${#SF_TUI_STYLE}"
else
  fail 'NO_COLOR should disable styling rather than fail'
fi
if TERM=dumb sf_tui_theme_config "$theme_config"; then
  assert_equal 0 "${#SF_TUI_STYLE}"
else
  fail 'a dumb terminal should disable styling rather than fail'
fi

# Auto mode uses the detected background and defaults to dark.
typeset -g auto_config=${theme_config/'"theme_mode":"dark"'/'"theme_mode":"auto"'}
[[ $auto_config == *'"theme_mode":"auto"'* ]] || fail 'auto theme fixture was not built'
sf_tui_background_mode() { REPLY=light; }

SF_TUI_BACKGROUND=''
sf_tui_theme_config "$auto_config" || fail "auto theme setup failed: $SF_TUI_HIGHLIGHT_ERROR"
assert_equal light "$SF_TUI_BACKGROUND"
assert_equal 'fg=#111111,bold' "$SF_TUI_STYLE[section.user]"
assert_equal '' "$SF_TUI_STYLE[message]"

SF_TUI_BACKGROUND=''
sf_tui_background_mode() { return 1 }
sf_tui_theme_config "$auto_config" || fail 'an unanswered probe should fall back to dark'
assert_equal dark "$SF_TUI_BACKGROUND"

sf_tui_theme_config "$theme_config" || fail "theme setup failed: $SF_TUI_HIGHLIGHT_ERROR"

span_texts() {
  local source=$1
  local -a texts=()
  integer index start end
  for (( index = 1; index <= ${#SF_TUI_HIGHLIGHT_SPANS}; index += 3 )); do
    start=$(( SF_TUI_HIGHLIGHT_SPANS[index] + 1 ))
    end=${SF_TUI_HIGHLIGHT_SPANS[index + 1]}
    [[ ${2-} == '' || ${SF_TUI_HIGHLIGHT_SPANS[index + 2]} == "$2" ]] ||
      continue
    texts+=( "${source[start,end]}" )
  done
  REPLY="${(j:,:)texts}"
}

# Syntax offsets count characters before multibyte text.
typeset code='é const x = "text"; // note'
SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_code_highlight "$code" js
span_texts "$code"
assert_equal 'const,"text",// note' "$REPLY"
assert_equal '2,7,fg=#222224' "${(j:,:)SF_TUI_HIGHLIGHT_SPANS[1,3]}"

typeset markdown=$'# Head\n**bold** [link](url) `code`\n```js\nconst x = 3;\n```'
SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight "$markdown"
span_texts "$markdown"
assert_equal $'# Head,**bold**,[link](url),`code`,```js,const,3,```' "$REPLY"
assert_equal '0,6,bold,underline,7,15,bold' \
  "${(j:,:)SF_TUI_HIGHLIGHT_SPANS[1,6]}"

markdown=$'```js\n\nconst value\n\t```'
SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight "$markdown"
span_texts "$markdown"
assert_equal $'```js,const,\t```' "$REPLY"

SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_markdown_highlight 'const x = 3;' $'```\tjs'
span_texts 'const x = 3;'
assert_equal 'const,3' "$REPLY"
sf_tui_markdown_highlight $'```\n' $'```\tjs\t0'
assert_equal '' "$REPLY"

sf_tui_markdown_highlight $'```js\nconst x = 3;'
assert_equal $'```\tjs\t0' "$REPLY"

# Block comments carry styling state across chunks.
SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_code_highlight '/* opened' js
span_texts '/* opened'
assert_equal '/* opened' "$REPLY"
SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_code_highlight 'still inside */ const x = 3;' js 0 1
span_texts 'still inside */ const x = 3;'
assert_equal 'still inside */,const,3' "$REPLY"

# Fence and block comment state carries from one line to the next.
sf_tui_markdown_highlight $'```js\n/* opened\n'
assert_equal $'```\tjs\t1' "$REPLY"
sf_tui_markdown_highlight $'closed */\n' $'```\tjs\t1'
assert_equal $'```\tjs\t0' "$REPLY"

# Hunk and file headers are styled apart from the changed lines.
typeset diff=$'@@ -1 +1 @@\n-old\n+new\n--- a/file\n+++ b/file\n---- rule'
SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_diff_highlight "$diff"
span_texts "$diff"
assert_equal '@@ -1 +1 @@,-,old,+,new,--- a/file,+++ b/file,---- rule' "$REPLY"
assert_equal "$SF_TUI_STYLE[clamp]" "$SF_TUI_HIGHLIGHT_SPANS[3]"
assert_equal bold "$SF_TUI_HIGHLIGHT_SPANS[18]"
assert_equal "$SF_TUI_STYLE[syntax.removed]" "$SF_TUI_HIGHLIGHT_SPANS[24]"

SF_TUI_STYLE[syntax.removed]='fg=red,bg=darkred'
typeset removed_word="$SF_TUI_STYLE[syntax.removed],bold"
typeset added_word="$SF_TUI_STYLE[syntax.added],bold"
typeset indent=$'heading\n'
diff=$'@@ -2,4 +2,4 @@\n-é one stays two\n-same dust\n+é red stays blue\n+same gold\n context\n--- first\n\\ No newline at end of file\n+++ last'
SF_TUI_HIGHLIGHT_SPANS=()
sf_tui_diff_highlight "$diff" ${#indent}
span_texts "$indent$diff" "$removed_word"
assert_equal 'one,two,dust,--,first' "$REPLY"
span_texts "$indent$diff" "$added_word"
assert_equal 'red,blue,gold,++,last' "$REPLY"

# Even totals do not imply balanced replacement blocks across context.
typeset fallback large=$'@@ -1,9 +1,9 @@\n-old\n+new'
repeat 8; do large+=$'\n context'; done
for fallback in \
  $'@@ -1 +1,2 @@\n-old\n+new\n+added' \
  $'@@ -1,3 +1,3 @@\n-removed\n context\n-old\n+new\n+added' \
  "$large" \
  $'@@ -1 +1 @@\n-a b c d e f g h i j k l m\n+new' \
  $'@@ -1 +1 @@\n-'${(l:257::a:):-}$'\n+new'; do
  SF_TUI_HIGHLIGHT_SPANS=()
  sf_tui_diff_highlight "$fallback"
  span_texts "$fallback" "$removed_word"
  assert_equal '' "$REPLY"
  span_texts "$fallback" "$added_word"
  assert_equal '' "$REPLY"
  span_texts "$fallback" "$SF_TUI_STYLE[syntax.added]"
  [[ $REPLY == '+new'* ]] || fail 'fallback lost line highlighting'
done
