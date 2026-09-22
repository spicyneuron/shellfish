#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp backend-request

typeset entry="$ROOT/bin/shellfish" session="$tmp/session.jsonl"
typeset response digest
jq -c --arg command "$SF_TEST_BACKEND" --arg cwd "$tmp" \
  '.runtime.backend.command = $command | .cwd = $cwd' \
  "$SF_TEST_SESSIONS/header-only.jsonl" >"$session"
print -r -- '{"type":"user","content":[{"type":"text","text":"old"}]}' >>"$session"
print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"answer"}]}' \
  >>"$session"
print -r -- '{"type":"state","name":"stored/value","value":{"revision":1}}' >>"$session"
print -r -- '{"type":"user","content":[{"type":"text","text":"composed request"}]}' >>"$session"

zsh -f "$entry" backend-request extra </dev/null >/dev/null 2>&1 &&
  fail 'backend-request accepted arguments'
zsh -f "$entry" backend-request </dev/null >/dev/null 2>&1 &&
  fail 'backend-request accepted an empty transcript'
digest=$(shasum <"$session")
response=$(SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_REQUEST="$tmp/request.json" \
  zsh -f "$entry" backend-request <"$session") ||
  fail 'backend-request failed'
jq -e '
  .type == "assistant" and .stop == "end" and
  .content == [{type:"text",text:"composed request\n"}]
' <<<"$response" >/dev/null || fail 'backend-request produced the wrong response'
jq -e '.tools == [] and .messages[-1].content[0].text == "composed request"' \
  "$tmp/request.json" >/dev/null || fail 'backend-request exposed unavailable tools'
assert_equal "$digest" "$(shasum <"$session")"

# Backend execution follows the session cwd, not the command's cwd.
typeset cwd_backend="$tmp/cwd-backend" cwd_session="$tmp/cwd-session.jsonl"
cat >"$cwd_backend" <<EOF
#!/usr/bin/env zsh
pwd -P >"$tmp/backend-cwd"
exec "$SF_TEST_BACKEND"
EOF
chmod +x "$cwd_backend"
jq -c --arg command "$cwd_backend" '
  if .type == "session" then .cwd="~" | .runtime.backend.command=$command else . end
' \
  "$session" >"$cwd_session"
HOME="$tmp" SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" backend-request \
  <"$cwd_session" >/dev/null || fail 'home-relative backend request failed'
assert_equal "${tmp:A}" "$(<"$tmp/backend-cwd")" 'backend ran outside the session cwd'

# jq modules resolve from the installation root.
mkdir -p "$tmp/lib"
print -r -- 'def canonical_request(:' >"$tmp/lib/backend.jq"
(
  builtin cd -- "$tmp"
  response=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" backend-request <session.jsonl)
  jq -e '.content == [{type:"text",text:"composed request\n"}]' \
    <<<"$response" >/dev/null
  assert_equal "$tmp" "$PWD"
)

cp "$session" "$tmp/invalid-transition.jsonl"
print -r -- '{"type":"user","content":[{"type":"text","text":"duplicate"}]}' \
  >>"$tmp/invalid-transition.jsonl"
zsh -f "$entry" backend-request <"$tmp/invalid-transition.jsonl" >/dev/null 2>&1 &&
  fail 'backend-request accepted an invalid record transition'

{
  sed '$d' "$session"
  tail -n 1 "$session" | jq -c '.content[0].text = "error"'
} >"$tmp/failing.jsonl"
SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" backend-request <"$tmp/failing.jsonl" \
  >/dev/null 2>"$tmp/backend-error" && fail 'backend-request accepted backend failure'
[[ $(<"$tmp/backend-error") == *'test backend failure'* ]] ||
  fail 'backend-request hid the backend error'

# Reject invalid backend event streams without exposing partial output.
typeset invalid_backend="$tmp/invalid-backend" invalid_session="$tmp/invalid-session.jsonl"
cat >"$invalid_backend" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- '{"type":"_assistant_message_delta","index":0,"text":"partial"}'
case $SF_TEST_INVALID_STREAM in
  malformed) print -r -- '{' ;;
  late)
    print -r -- '{"type":"_assistant_end","stop":"end"}'
    print -r -- '{"type":"_assistant_message_delta","index":0,"text":"late"}'
    ;;
  assembly)
    print -r -- '{"type":"_assistant_tool_call_delta","index":1,"id":"bad","name":"shell","input":"{"}'
    print -r -- '{"type":"_assistant_end","stop":"tool_calls"}'
    ;;
esac
ZSH
chmod +x "$invalid_backend"
{
  IFS= read -r header
  jq -c --arg command "$invalid_backend" '.runtime.backend.command = $command' <<<"$header"
  cat
} <"$session" >"$invalid_session"
typeset invalid_mode
for invalid_mode in malformed late assembly; do
  if SF_TEST_INVALID_STREAM=$invalid_mode zsh -f "$entry" backend-request \
      <"$invalid_session" >"$tmp/invalid-$invalid_mode.out" \
      2>"$tmp/invalid-$invalid_mode.err"; then
    fail "backend-request accepted $invalid_mode backend output"
  fi
  [[ ! -s "$tmp/invalid-$invalid_mode.out" ]] ||
    fail "backend-request exposed $invalid_mode backend output"
  [[ $(<"$tmp/invalid-$invalid_mode.err") == *'backend emitted an invalid event stream'* ]] ||
    fail "backend-request misreported $invalid_mode backend output"
done
