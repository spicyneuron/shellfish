#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp request-commands

typeset entry="$ROOT/bin/shellfish" request_session="$tmp/session.jsonl"
typeset request request_record request_response request_digest
jq -c --arg command "$SF_TEST_BACKEND" --arg cwd "$tmp" \
  '.backend.command = $command | .cwd = $cwd' \
  "$SF_TEST_SESSIONS/header-only.jsonl" >"$request_session"
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$request_session"
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"answer"}]}' \
  >>"$request_session"

# Read-only request commands compose one provider call without claiming or
# mutating the durable turn.
print -r -- '{}' | zsh -f "$entry" build-request --session "$tmp/missing.jsonl" \
  >/dev/null 2>&1 && fail 'build-request accepted a missing session'
print -r -- '{}' | zsh -f "$entry" send-request --session "$tmp/missing.jsonl" \
  >/dev/null 2>&1 && fail 'send-request accepted a missing session'
zsh -f "$entry" build-request --session "$request_session" --tools '{}' \
  >/dev/null 2>&1 && fail 'build-request accepted invalid tools'
zsh -f "$entry" build-request --session "$request_session" --tools '[{}]' \
  >/dev/null 2>&1 && fail 'build-request accepted an invalid tool schema'
request_record=$(jq -cn --arg text 'composed request' \
  '{type:"message",role:"user",content:[{type:"text",text:$text}]}')
request_digest=$(shasum <"$request_session")
request=$(print -r -- "$request_record" |
  zsh -f "$entry" build-request --session "$request_session" --tools '[]') ||
  fail 'build-request failed'
jq -e '
  .tools == [] and .messages[-1] == {
    role:"user",content:[{type:"text",text:"composed request"}]
  }
' <<<"$request" >/dev/null || fail 'build-request produced the wrong request'
request_response=$(print -r -- "$request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" send-request --session "$request_session") ||
  fail 'send-request failed'
jq -e '
  .type == "message" and .role == "assistant" and .stop == "end" and
  .content == [{type:"text",text:"composed request\n"}]
' <<<"$request_response" >/dev/null || fail 'send-request produced the wrong response'
assert_equal "$request_digest" "$(shasum <"$request_session")"

print -r -- '{"type":"message","role":"assistant","stop":"end","content":[]}' |
  zsh -f "$entry" build-request --session "$request_session" >/dev/null 2>&1 &&
  fail 'build-request accepted an invalid record transition'
print -r -- '{}' | zsh -f "$entry" send-request --session "$request_session" \
  >/dev/null 2>&1 && fail 'send-request accepted an invalid request'
printf '%s\n%s\n' "$request" "$request" |
  zsh -f "$entry" send-request --session "$request_session" >/dev/null 2>&1 &&
  fail 'send-request accepted multiple requests'
jq '.transport.endpoint = "https://elsewhere.invalid"' <<<"$request" |
  zsh -f "$entry" send-request --session "$request_session" >/dev/null 2>&1 &&
  fail 'send-request accepted transport from outside the frozen runtime'
typeset separator_request separator_response
separator_request=$(jq --arg text $'record separator: \x1e' \
  '.messages[-1].content[0].text = $text' <<<"$request")
separator_response=$(print -r -- "$separator_request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" send-request --session "$request_session") ||
  fail 'send-request rejected valid assistant text'
jq -e --arg text $'record separator: \x1e\n' '.content[0].text == $text' \
  <<<"$separator_response" >/dev/null || fail 'send-request changed assistant text'
typeset failing_request
failing_request=$(jq '.messages[-1].content[0].text = "error"' <<<"$request")
print -r -- "$failing_request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" send-request --session "$request_session" \
    >/dev/null 2>"$tmp/send-request-error" && fail 'send-request accepted backend failure'
[[ $(<"$tmp/send-request-error") == *'test backend failure'* ]] ||
  fail 'send-request hid the backend error'

# The response decoder rejects malformed JSON and events after response end.
typeset invalid_backend="$tmp/invalid-backend" invalid_session="$tmp/invalid-session.jsonl"
cat >"$invalid_backend" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- '{"type":"_assistant_delta","index":0,"text":"partial"}'
case $SF_TEST_INVALID_STREAM in
  malformed) print -r -- '{' ;;
  late)
    print -r -- '{"type":"_assistant_response_end","stop":"end"}'
    print -r -- '{"type":"_assistant_delta","index":0,"text":"late"}'
    ;;
  assembly)
    print -r -- '{"type":"_assistant_tool_call_delta","index":1,"id":"bad","name":"shell","input":"{"}'
    print -r -- '{"type":"_assistant_response_end","stop":"tool_calls"}'
    ;;
esac
ZSH
chmod +x "$invalid_backend"
{
  IFS= read -r header
  jq -c --arg command "$invalid_backend" '.backend.command = $command' <<<"$header"
  cat
} <"$request_session" >"$invalid_session"
typeset invalid_mode
for invalid_mode in malformed late assembly; do
  if print -r -- "$request" | SF_TEST_INVALID_STREAM=$invalid_mode \
      zsh -f "$entry" send-request --session "$invalid_session" \
      >"$tmp/invalid-$invalid_mode.out" 2>"$tmp/invalid-$invalid_mode.err"; then
    fail "send-request accepted $invalid_mode backend output"
  fi
  [[ ! -s "$tmp/invalid-$invalid_mode.out" ]] ||
    fail "send-request exposed $invalid_mode backend output"
  [[ $(<"$tmp/invalid-$invalid_mode.err") == *'backend emitted an invalid event stream'* ]] ||
    fail "send-request misreported $invalid_mode backend output"
done
