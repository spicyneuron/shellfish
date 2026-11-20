#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-tool-protocol
mkdir "$tmp/host-temp"
export TMPDIR="$tmp/host-temp" TMPPREFIX="$tmp/manifest-prefix"
sf_test_frozen_profile
typeset session stream="$tmp/stream"

# Tool-only protocol failures and interrupted state remain composition checks.
typeset protocol="$tmp/protocol"
cat >"$protocol" <<'ZSH'
#!/usr/bin/env zsh
case $(jq -r .command) in
  action)
    print -r -u3 -- '{"state_update":[{"name":"tool/before-error","value":true}]}'
    print -r -u3 -- '{"content":[{"type":"text","text":"discarded"}]}'
    print -r -u3 -- '{"action":"deny"}'
    print -r -u3 -- '{"state_update":[{"name":"tool/after-error","value":true}]}'
    ;;
  malformed) print -r -u3 -- '{' ;;
  stream)
    print -r -u3 -- '{"state_update":[{"name":"tool/live","value":true}]}'
    : >"$TOOL_MARKER"
    sleep 30
    ;;
  huge) jq -cn '{reason:("x" * 70000)}' >&3 ;;
  image)
    print -r -- caption
    # Larger than one Linux argument, so no step may pass it through argv.
    printf '{"content":[{"type":"image","url":"data:image/png;base64,%s"}]}\n' \
      "$(head -c 240000 /dev/zero | base64 | tr -d '\n')" >&3
    ;;
  twice)
    repeat 2 printf '{"content":[{"type":"image","url":"data:image/png;base64,%s"}]}\n' \
      "$(head -c 30000 /dev/zero | base64 | tr -d '\n')" >&3
    ;;
  remote) print -r -u3 -- '{"content":[{"type":"image","url":"https://example.com/a.png"}]}' ;;
  flood)
    repeat 2 printf '{"content":[{"type":"image","url":"data:image/png;base64,%s"}]}\n' \
      "$(head -c 30000 /dev/zero | base64 | tr -d '\n')" >&3
    : >"$TOOL_MARKER"
    sleep 30
    ;;
esac
ZSH
chmod +x "$protocol"
sf_test_shell_tool '.user_preview_lines=3' "$protocol"
SF_TEST_PROFILE=$(jq -c '.sandbox.enabled=false' <<<"$SF_TEST_PROFILE")
for mode in action malformed; do
  session="$tmp/protocol-$mode.jsonl"
  sf_test_session "$session"
  SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COUNT=2 \
    SF_TEST_PROVIDER_TOOL_COMMAND=$mode SF_TEST_PROVIDER_REQUEST="$tmp/control-request.json" \
    sf_test_run protocol "$session" >"$stream" || fail "invalid $mode control failed the turn"
  assert_canonical_session "$session"
  jq -e -s '
    ([.[] | select(.type == "tool_result")] | length == 2 and
      all(.[]; .exit_code == 1 and .model_text == "tool returned invalid control data" and
        (has("model_content") | not))) and
    all(.[]; .type != "error") and .[-1].type == "assistant" and .[-1].stop == "end"
  ' "$session" >/dev/null || fail "invalid $mode control did not settle both calls and continue"
  jq -e '[.messages[] | select(.type == "tool_result")] |
    length == 2 and all(.[]; .exit_code == 1 and .content == "tool returned invalid control data")' \
    "$tmp/control-request.json" >/dev/null || fail "provider did not receive $mode failures"
  [[ $mode != action ]] || jq -e -s '
    [.[] | select(.type == "state_update")] | length == 2 and
      all(.[]; .name == "tool/before-error" and .value == true)
  ' "$session" >/dev/null || fail 'invalid control lost previously accepted tool state'
done

# State is durable while the tool is running and remains so after interruption.
typeset live_marker="$tmp/tool-live"
session="$tmp/protocol-stream.jsonl"
sf_test_session "$session"
jq -cn '{type:"user",content:[{type:"text",text:"protocol"}]}' |
  SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND=stream \
  TOOL_MARKER=$live_marker "$ROOT/bin/shellfish" run --jsonl --session "$session" \
  >"$stream" &
integer live_pid=$! live_status=0
sf_test_wait test -e "$live_marker" || fail 'tool did not reach its wait'
sf_test_wait jq -e -s \
    'any(.[]; .type == "state_update" and .name == "tool/live")' "$session" \
    >/dev/null || fail 'tool state was not committed while running'
kill -TERM "$live_pid" 2>/dev/null
wait "$live_pid" || live_status=$?
(( live_status == 143 )) || fail 'interrupted tool returned the wrong status'
jq -e -s 'any(.[]; .type == "state_update" and .name == "tool/live")' \
  "$session" >/dev/null || fail 'interruption lost committed tool state'
assert_canonical_session "$session"

# A line or a call's content beyond the content limit fails the call, not the turn.
for mode in huge twice; do
  session="$tmp/protocol-$mode.jsonl"
  sf_test_session "$session"
  SHELLFISH_MAX_CONTENT_KB=64 SF_TEST_PROVIDER_TOOL_CALL=1 \
    SF_TEST_PROVIDER_TOOL_COMMAND=$mode \
    sf_test_run protocol "$session" >"$stream" || fail "oversized $mode content failed the turn"
  jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0] |
    .exit_code == 1 and .model_text == "tool result exceeds content limit"' \
    <"$stream" >/dev/null || fail "oversized $mode content did not fail the call"
done

# Cancelling a call already past the content limit still cancels the turn.
typeset flood_marker="$tmp/tool-flood"
session="$tmp/protocol-flood.jsonl"
sf_test_session "$session"
jq -cn '{type:"user",content:[{type:"text",text:"protocol"}]}' |
  SHELLFISH_MAX_CONTENT_KB=64 SF_TEST_PROVIDER_TOOL_CALL=1 \
  SF_TEST_PROVIDER_TOOL_COMMAND=flood TOOL_MARKER=$flood_marker \
  "$ROOT/bin/shellfish" run --jsonl --session "$session" >"$stream" &
integer flood_pid=$! flood_status=0
sf_test_wait test -e "$flood_marker" || fail 'flooding tool did not reach its wait'
kill -USR1 "$flood_pid" 2>/dev/null
wait "$flood_pid" || flood_status=$?
(( flood_status == 130 )) || fail "cancelled overflow returned status $flood_status"
jq -e -s '[.[] | select(.type == "tool_result") | .model_text] == ["tool call interrupted"] and
  .[-1] == {type:"error",section:2,user_text:"Cancelled."} and
  ([.[] | select(.type == "assistant")] | length) == 1' "$session" >/dev/null ||
  fail 'cancelled overflow did not settle as a cancellation'
assert_canonical_session "$session"

# Content parts follow stdout as model content and reach the provider as parts.
session="$tmp/protocol-image.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_REQUEST="$tmp/image-request.json" SF_TEST_PROVIDER_TOOL_CALL=1 \
  SF_TEST_PROVIDER_TOOL_COMMAND=image \
  sf_test_run protocol "$session" >"$stream" || fail 'image content turn failed'
assert_canonical_session "$session"
jq -e -s '[.[] | select(.type == "tool_result")][0] |
  (has("model_text") | not) and (.model_content | length == 2) and
  .model_content[0] == {type:"text",text:"caption\n"} and
  (.model_content[1] | .type == "image" and (.url | startswith("data:image/png;base64,")) and
    (.url | length) > 131072)' "$session" >/dev/null ||
  fail 'image content did not settle as model content'
jq -e '[.messages[] | select(.type == "tool_result")][0].content |
  type == "array" and .[0] == {type:"text",text:"caption\n"} and .[1].type == "image"' \
  "$tmp/image-request.json" >/dev/null || fail 'image content did not reach the provider'

# Transcript images are inline data URIs only.
session="$tmp/protocol-remote.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND=remote \
  sf_test_run protocol "$session" >"$stream" || fail 'a remote image failed the turn'
assert_canonical_session "$session"
jq -e -s '([.[] | select(.type == "tool_result")][0] |
  .exit_code == 1 and .model_text == "tool returned invalid control data" and
  (has("model_content") | not)) and .[-1].type == "assistant"' \
  "$session" >/dev/null || fail 'a remote image did not fail the call'

print -r -- ok
