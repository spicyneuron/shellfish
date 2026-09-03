#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source chat/transport.zsh
sf_test_tmp transport

typeset -ga ZLE_CALLS=()
zle() { ZLE_CALLS+=( "$*" ); }

SF_CHAT_TRANSPORT_LINES=(
  '{"type":"_assistant_delta","text":"one"}'
  '{"type":"_turn_usage","input_tokens":2,"output_tokens":1}'
)
sf_chat_transport_next null
assert_equal 'assistant_delta,one,,,,,' "${(j:,:)reply}"
sf_chat_transport_has_pending || fail 'decoded transport tail was not pending'
sf_chat_transport_next null
assert_equal 'turn_usage,2 ↑ 1 ↓,,,,,' "${(j:,:)reply}"
if sf_chat_transport_has_pending; then
  fail 'decoded transport batch remained pending'
fi

# Runtime updates affect later events already buffered in the same read.
typeset runtime=$(head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl" |
  jq -c 'del(.type,.format_version,.cwd,.created)')
typeset updated_runtime=$(jq -c '.profile.context_window = 200' <<<"$runtime")
SF_CHAT_TRANSPORT_LINES=(
  "$(jq -cn --argjson runtime "$updated_runtime" '{type:"_session_update",runtime:$runtime}')"
  '{"type":"_turn_usage","input_tokens":75,"output_tokens":5}'
)
sf_chat_transport_next "$runtime"
assert_equal "session_update,$updated_runtime,,,,," "${(j:,:)reply}"
sf_chat_transport_next "$updated_runtime"
assert_equal 'turn_usage,75 ↑ 5 ↓ 37% of 200 ◔,,,,,' "${(j:,:)reply}"

# A batch is accepted atomically; malformed trailing input exposes no prefix.
SF_CHAT_TRANSPORT_LINES=(
  '{"type":"_assistant_delta","text":"speculative"}'
  broken
)
integer next_status=0
sf_chat_transport_next null || next_status=$?
assert_equal 2 "$next_status"
if sf_chat_transport_has_pending; then
  fail 'malformed transport batch exposed a partial prefix'
fi

# A valid batch may contain only ignored durable startup records.
typeset header=$(head -n 1 "$SF_TEST_SESSIONS/complete.jsonl")
SF_CHAT_TRANSPORT_LINES=( "$header" )
next_status=0
sf_chat_transport_next "$header" || next_status=$?
assert_equal 1 "$next_status"

exec {SF_CHAT_TRANSPORT_INPUT_FD}>"$tmp/reply.jsonl"
sf_chat_transport_reply permission_1 approve
exec {SF_CHAT_TRANSPORT_INPUT_FD}>&-
SF_CHAT_TRANSPORT_INPUT_FD=''
jq -e '. == {type:"_tool_permission_response",id:"permission_1",decision:"approve"}' \
  "$tmp/reply.jsonl" >/dev/null || fail 'permission reply was not encoded canonically'

SF_CHAT_TRANSPORT_EOF=1
SF_CHAT_TRANSPORT_EXIT_STATUS=7
SF_CHAT_TRANSPORT_EXIT_DETAIL=failed
sf_chat_transport_result
assert_equal '7,failed' "${(j:,:)reply}"
assert_equal 0 "$SF_CHAT_TRANSPORT_EOF"
if sf_chat_transport_result; then
  fail 'transport result was returned twice'
fi

print -rn -- $'first\tsecond\nthird' >"$tmp/exec.error"
SF_CHAT_TRANSPORT_ERROR_FILE="$tmp/exec.error"
sf_chat_transport_close
assert_equal 'first second third' "$SF_CHAT_TRANSPORT_EXIT_DETAIL"
[[ ! -e $tmp/exec.error ]] || fail 'transport error file was not removed'

# Exercise the real coprocess attachment, write, read, watcher, and close path.
SF_CHAT_TRANSPORT_COMMAND=( "${commands[zsh]}" -f -c \
  'IFS= read -r line; print -r -- "$line"' )
sf_chat_transport_start '{"ping":true}' callback || fail "$SF_CHAT_TRANSPORT_ERROR"
[[ $SF_CHAT_TRANSPORT_ERROR_FILE == "${${TMPDIR:-/tmp}:A}/shellfish-$EUID/transport/exec-error."* ]]
[[ $ZLE_CALLS[-1] == '-F -w '*' callback' ]] || fail 'transport watcher was not installed'
sf_chat_transport_read "$SF_CHAT_TRANSPORT_OUTPUT_FD"
assert_equal '{"ping":true}' "$SF_CHAT_TRANSPORT_LINES[1]"
sf_chat_transport_read "$SF_CHAT_TRANSPORT_OUTPUT_FD"
sf_chat_transport_is_complete || fail 'transport EOF was not recorded'
sf_chat_transport_result
assert_equal '0,' "${(j:,:)reply}"
[[ $ZLE_CALLS == *'-F '* ]] || fail 'transport watcher was not removed'

# A command that vanishes before the initial write cannot terminate chat with SIGPIPE.
SF_CHAT_TRANSPORT_COMMAND=( "$tmp/missing" )
if sf_chat_transport_start '{}' callback; then
  fail 'missing transport command unexpectedly started'
fi
assert_equal 'cannot write to exec process' "$SF_CHAT_TRANSPORT_ERROR"
sf_chat_transport_stop
