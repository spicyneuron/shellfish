#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/transport.zsh
sf_test_tmp transport

typeset -ga ZLE_CALLS=()
zle() { ZLE_CALLS+=( "$*" ); }

# Drain decoded batches.
SF_TUI_TRANSPORT_LINES=(
  '{"type":"_assistant_message_delta","index":0,"text":"one"}'
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"one"}],"usage":{"input_tokens":2,"output_tokens":1}}'
)
sf_tui_transport_next null
assert_equal 'assistant_message_delta,0,one,,,,' "${(j:,:)reply}"
sf_tui_transport_has_pending || fail 'decoded transport tail was not pending'
sf_tui_transport_next null
assert_equal 'turn_usage,2 ↑ 1 ↓,,,,,' "${(j:,:)reply}"
if sf_tui_transport_has_pending; then
  fail 'decoded transport batch remained pending'
fi

# Apply buffered runtime updates.
typeset runtime=$(head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl" |
  jq -c 'del(.type,.format_version,.cwd,.created)')
typeset updated_runtime=$(jq -c '.profile.context_window = 200' <<<"$runtime")
SF_TUI_TRANSPORT_LINES=(
  "$(jq -cn --argjson runtime "$updated_runtime" '{type:"_session_update",runtime:$runtime}')"
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"two"}],"usage":{"input_tokens":75,"output_tokens":5}}'
)
sf_tui_transport_next "$runtime"
assert_equal "session_update,$updated_runtime,,,,," "${(j:,:)reply}"
sf_tui_transport_next "$updated_runtime"
assert_equal 'turn_usage,75 ↑ 5 ↓ 38% of 200 ◔,,,,,' "${(j:,:)reply}"

# Reject malformed batches atomically.
SF_TUI_TRANSPORT_LINES=(
  '{"type":"_assistant_message_delta","index":0,"text":"speculative"}'
  broken
)
integer next_status=0
sf_tui_transport_next null || next_status=$?
assert_equal 2 "$next_status"
if sf_tui_transport_has_pending; then
  fail 'malformed transport batch exposed a partial prefix'
fi

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

# Start session creation without input.
SF_TUI_TRANSPORT_COMMAND=( "${commands[zsh]}" -f -c \
  'print -r -- '\''{"type":"_session_created","path":"/tmp/new.jsonl"}'\''' )
sf_tui_transport_start '' callback || fail 'transport required turn input'
sf_tui_transport_read "$SF_TUI_TRANSPORT_OUTPUT_FD"
sf_tui_transport_next null
assert_equal 'session_created,/tmp/new.jsonl,,,,,' "${(j:,:)reply}"
sf_tui_transport_read "$SF_TUI_TRANSPORT_OUTPUT_FD"
sf_tui_transport_result
assert_equal '0,' "${(j:,:)reply}"
