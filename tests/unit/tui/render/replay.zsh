#!/usr/bin/env zsh

# Reload translates durable records into presentation events.

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh
sf_test_tmp replay

typeset -ga SF_TEST_EVENTS=()
sf_tui_event() { SF_TEST_EVENTS+=( "${(j:|:)@}" ); }
replayed() { REPLY="${(F)SF_TEST_EVENTS}" }

# Records replay in durable order.
SF_TEST_EVENTS=()
typeset esc=$'\e'
{
  head -n 1 "$SF_TEST_SESSIONS/tool-paired.jsonl" | jq -c \
    --slurpfile read "$ROOT/share/default/tools/read_file/manifest.json" \
    --slurpfile shell "$ROOT/share/default/tools/shell/manifest.json" \
    '.harness.tools = [
      {name:"read_file",command:"/bin/true",settings:"/tmp/settings",manifest:$read[0]},
      {name:"shell",command:"/bin/true",settings:"/tmp/settings",manifest:$shell[0]}]'
  tail -n +2 "$SF_TEST_SESSIONS/tool-paired.jsonl"
} >"$tmp/tools.jsonl"
sf_tui_reload "$tmp/tools.jsonl" || fail "$SF_PRESENT_ERROR"
replayed
assert_equal "user|Use both tools|||||
assistant_start||||||
assistant_end||||||
tool_call|call_1|read_file · README.md|read_file|0||
tool_result|call_1|read_file · README.md
contents
second line|read_file|0||
tool_call|call_2|shell
make test|shell|0||
tool_result|call_2|shell
make test
failed${esc}[31m
exit 1|shell|0||
assistant_start||||||
assistant_message_delta|0|Done||||
assistant_end||||||
hook_result|session_start|/hooks/test/run||-1|1|" "$REPLY"

# Replay omits correlated hook views that preceded the tool result, but keeps
# later hook notes.
{
  head -n 1 "$tmp/tools.jsonl"
  print -r -- '{"type":"user","content":[{"type":"text","text":"run it"}]}'
  print -r -- '{"type":"assistant","stop":"tool_calls","content":[]}'
  print -r -- '{"type":"hook_result","hook":"pre_tool_use","script":"/hooks/pre/run","input":{},"stdout":"before","stderr":"","exit_code":0,"tool_use_id":"call_1"}'
  print -r -- '{"type":"tool_result","call_id":"call_1","name":"shell","input":{"command":"true"},"stdout":"done","stderr":"","exit_code":0}'
  print -r -- '{"type":"hook_result","hook":"post_tool_use","script":"/hooks/post/run","input":{},"stdout":"after","stderr":"","exit_code":0,"tool_use_id":"call_1"}'
} >"$tmp/correlated.jsonl"
SF_TEST_EVENTS=()
sf_tui_reload "$tmp/correlated.jsonl" || fail "$SF_PRESENT_ERROR"
replayed
[[ $REPLY != *'/hooks/pre/run'* ]] || fail "replayed pre-tool hook: $REPLY"
[[ $REPLY == *'hook_result|post_tool_use|/hooks/post/run||-1|1|call_1'* ]] ||
  fail "missing replayed post-tool hook: $REPLY"

# The header replaces stale runtime state.
SF_PRESENT_IDENTITY=stale/model
SF_PRESENT_FOOTER='stale/model · stale usage'
sf_tui_reload "$SF_TEST_SESSIONS/header-only.jsonl" || fail "$SF_PRESENT_ERROR"
assert_equal test/fake-model "$SF_PRESENT_FOOTER"
assert_equal fake-model "$(jq -r '.profile.request.model' <<<"$SF_PRESENT_RUNTIME")"

# Errors end their replayed turn.
SF_TEST_EVENTS=()
cp "$SF_TEST_SESSIONS/interrupted.jsonl" "$tmp/failed.jsonl"
print -r -- '{"type":"error","user_text":"Turn interrupted."}' >>"$tmp/failed.jsonl"
sf_tui_reload "$tmp/failed.jsonl" || fail "$SF_PRESENT_ERROR"
replayed
assert_equal 'user|Please continue|||||
error|Turn interrupted.||end|||' "$REPLY"

cp "$tmp/tools.jsonl" "$tmp/invalid.jsonl"
print -r -- broken >>"$tmp/invalid.jsonl"
if sf_tui_reload "$tmp/invalid.jsonl"; then
  fail 'accepted an invalid durable transcript'
fi
