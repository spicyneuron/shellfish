#!/usr/bin/env zsh

# Replay behavior at the input boundary: sf_tui_reload turns a durable session
# into the same ordered event tuples live presentation receives. These assert the
# tuples themselves, so they hold across any presentation implementation.

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh
sf_test_tmp replay

typeset -ga SF_TEST_EVENTS=()
sf_tui_event() { SF_TEST_EVENTS+=( "${(j:|:)@}" ); }
replayed() { REPLY="${(F)SF_TEST_EVENTS}" }

# Replay opens relative session paths before changing jq's working directory. A
# broken module under the session's own directory would be loaded if jq resolved
# it against the caller's copy.
mkdir -p "$tmp/lib/runtime"
print -r -- 'def canonical_session_header(:' >"$tmp/lib/runtime/schema.jq"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$tmp/session.jsonl"
(
  builtin cd -- "$tmp"
  sf_tui_reload session.jsonl || fail "$SF_PRESENT_ERROR"
  assert_equal test/fake-model "$SF_PRESENT_FOOTER"
  assert_equal "$tmp" "$PWD"
)

# Durable records replay in recorded order, pairing each tool call with its
# result and keeping hook output after the assistant text it follows.
SF_TEST_EVENTS=()
typeset esc=$'\e'
sf_tui_reload "$SF_TEST_SESSIONS/tool-paired.jsonl" || fail "$SF_PRESENT_ERROR"
replayed
assert_equal "user|Use both tools|||||
assistant_start||||||
assistant_end||||||
tool_call|call_1|read_file|{\"file_path\":\"README.md\"}||json|
tool_result|call_1|hidden|contents
second line|plain||
tool_call|call_2|shell|{\"command\":\"make test\"}||json|
tool_result|call_2|1|failed${esc}[31m|plain||
assistant_start||||||
assistant_message_delta|0|Done||||
assistant_end||||||
hook_result|test|project|Use fixtures.|||" "$REPLY"

# Replay is the only source of the runtime, so it initializes the frozen profile
# from the durable header and clears any usage the previous session left behind.
SF_PRESENT_IDENTITY=stale/model
SF_PRESENT_FOOTER='stale/model · stale usage'
sf_tui_reload "$SF_TEST_SESSIONS/header-only.jsonl" || fail "$SF_PRESENT_ERROR"
assert_equal test/fake-model "$SF_PRESENT_FOOTER"
assert_equal fake-model "$(jq -r '.profile.request.model' <<<"$SF_PRESENT_RUNTIME")"

# A durable turn error replays as an error that ends its turn, so a later record
# opens a new section rather than joining the failed one.
SF_TEST_EVENTS=()
cp "$SF_TEST_SESSIONS/interrupted.jsonl" "$tmp/failed.jsonl"
print -r -- '{"type":"turn_error","message":"Turn interrupted."}' >>"$tmp/failed.jsonl"
sf_tui_reload "$tmp/failed.jsonl" || fail "$SF_PRESENT_ERROR"
replayed
assert_equal 'user|Please continue|||||
error|Turn interrupted.||end|||' "$REPLY"

cp "$SF_TEST_SESSIONS/tool-paired.jsonl" "$tmp/invalid.jsonl"
print -r -- broken >>"$tmp/invalid.jsonl"
if sf_tui_reload "$tmp/invalid.jsonl"; then
  fail 'accepted an invalid durable transcript'
fi

# Replay is the only source of the runtime, so a malformed header leaves the
# client nothing to present.
jq -c 'del(.backend)' "$SF_TEST_SESSIONS/header-only.jsonl" >"$tmp/bad-header.jsonl"
if sf_tui_reload "$tmp/bad-header.jsonl"; then
  fail 'accepted a malformed session header'
fi
