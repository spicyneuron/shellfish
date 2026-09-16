#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/transport.zsh
sf_test_tmp transport

typeset -ga ZLE_CALLS=()
zle() { ZLE_CALLS+=( "$*" ); }

# Encode permission replies.
exec {SF_TUI_TRANSPORT_INPUT_FD}>"$tmp/reply.jsonl"
sf_tui_transport_reply permission_1 approve
exec {SF_TUI_TRANSPORT_INPUT_FD}>&-
SF_TUI_TRANSPORT_INPUT_FD=''
jq -e '. == {type:"_tool_permission_response",id:"permission_1",decision:"approve"}' \
  "$tmp/reply.jsonl" >/dev/null || fail 'permission reply was not encoded canonically'

# Normalize transport errors.
print -rn -- $'first\tsecond\nthird' >"$tmp/exec.error"
SF_TUI_TRANSPORT_ERROR_FILE="$tmp/exec.error"
sf_tui_transport_close
assert_equal 'first second third' "$SF_TUI_TRANSPORT_EXIT_DETAIL"
[[ ! -e $tmp/exec.error ]] || fail 'transport error file was not removed'

# Complete the coprocess lifecycle.
SF_TUI_TRANSPORT_COMMAND=( "${commands[zsh]}" -f -c \
  'IFS= read -r line; print -r -- "$line"' )
sf_tui_transport_start '{"ping":true}' callback || fail "$SF_TUI_TRANSPORT_ERROR"
sf_tui_transport_read "$SF_TUI_TRANSPORT_OUTPUT_FD"
assert_equal '{"ping":true}' "$SF_TUI_TRANSPORT_LINES[1]"
sf_tui_transport_read "$SF_TUI_TRANSPORT_OUTPUT_FD"
sf_tui_transport_is_complete || fail 'transport EOF was not recorded'
sf_tui_transport_result
assert_equal '0,' "${(j:,:)reply}"

# Start a stream without input.
SF_TUI_TRANSPORT_COMMAND=( "${commands[zsh]}" -f -c 'print -r -- ready' )
sf_tui_transport_start '' callback || fail 'transport required turn input'
sf_tui_transport_read "$SF_TUI_TRANSPORT_OUTPUT_FD"
assert_equal ready "$SF_TUI_TRANSPORT_LINES[1]"
sf_tui_transport_read "$SF_TUI_TRANSPORT_OUTPUT_FD"
sf_tui_transport_result
assert_equal '0,' "${(j:,:)reply}"
