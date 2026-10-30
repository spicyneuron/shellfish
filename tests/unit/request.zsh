#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp request

typeset entry="$ROOT/bin/shellfish" session="$tmp/session.jsonl"
typeset response digest
jq -c --arg provider "${SF_TEST_PROVIDER:h}" --arg cwd "$tmp" \
  '.model.provider = $provider | .cwd = $cwd |
    .model.config = {example:{paths:["./data","~/data","@data"],values:[null,false,2]}}' \
  "$SF_TEST_SESSIONS/header-only.jsonl" >"$session"
print -r -- '{"type":"user","content":[{"type":"text","text":"old"}]}' >>"$session"
print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"answer"}]}' \
  >>"$session"
print -r -- '{"type":"state_update","name":"stored/value","value":{"revision":1}}' >>"$session"
print -r -- '{"type":"user","content":[{"type":"text","text":"composed request"}]}' >>"$session"

zsh -f "$entry" request extra </dev/null >/dev/null 2>&1 &&
  fail 'request accepted a positional argument'
zsh -f "$entry" request --model </dev/null >/dev/null 2>&1 &&
  fail 'request accepted a missing model value'
zsh -f "$entry" request </dev/null >/dev/null 2>&1 &&
  fail 'request accepted an empty transcript'
digest=$(shasum <"$session")
response=$(SF_TEST_PROVIDER_DELAY=0 SF_TEST_PROVIDER_REQUEST="$tmp/request.json" \
  zsh -f "$entry" request <"$session") ||
  fail 'request failed'
jq -e '
  .type == "assistant" and .stop == "end" and
  .content == [{type:"text",text:"composed request\n"}]
' <<<"$response" >/dev/null || fail 'request produced the wrong response'
jq -e '.tools == [] and .messages[-1].content[0].text == "composed request"' \
  "$tmp/request.json" >/dev/null || fail 'request exposed unavailable tools'
jq -e '.config == {example:{paths:["./data","~/data","@data"],values:[null,false,2]}} and
  .request == {model:"fake-model"}' "$tmp/request.json" >/dev/null ||
  fail 'provider configuration was changed or mixed with provider parameters'
assert_equal "$digest" "$(shasum <"$session")"

# Model overrides replace the header model and merge only with each other.
mkdir -p "$SHELLFISH_DIR/models/review/provider" "$SHELLFISH_DIR/profiles"
ln -s "$SF_TEST_PROVIDER" "$SHELLFISH_DIR/models/review/provider/run"
print -r -- '{"endpoint":"https://review.invalid/api"}' \
  >"$SHELLFISH_DIR/models/review/provider/manifest.json"
print -r -- '{"hooks":["missing"]}' >"$SHELLFISH_DIR/profiles/default.jsonc"
cat >"$SHELLFISH_DIR/models/review/fast.jsonc" <<'JSON'
{
  "provider": "./provider",
  "config": {"http_timeout": 60},
  "request": {"model": "review-model", "max_tokens": 2048}
}
JSON
response=$(SF_TEST_PROVIDER_DELAY=0 SF_TEST_PROVIDER_REQUEST="$tmp/override-request.json" \
  zsh -f "$entry" request --model review/fast \
    -m '{"request":{"temperature":0.3}}' <"$session") || fail 'named model override failed'
jq -e '.content == [{type:"text",text:"composed request\n"}]' <<<"$response" >/dev/null
jq -e '.endpoint == "https://review.invalid/api" and .config == {http_timeout:60} and
  .request == {model:"review-model",max_tokens:2048,temperature:0.3} and .tools == [] and
  .messages[-1].content[0].text == "composed request"
' "$tmp/override-request.json" >/dev/null || fail 'model override merged with the header model'
assert_equal "$digest" "$(shasum <"$session")" 'model override changed the transcript'

# Explicit paths and inline model objects use the same resolution rules.
SF_TEST_PROVIDER_DELAY=0 SF_TEST_PROVIDER_REQUEST="$tmp/path-request.json" \
  zsh -f "$entry" request -m "$SHELLFISH_DIR/models/review/fast.jsonc" \
    <"$session" >/dev/null
jq -e '.request.model == "review-model"' "$tmp/path-request.json" >/dev/null
typeset inline_model
inline_model=$(jq -cn --arg provider "${SF_TEST_PROVIDER:h}" '
  {provider:$provider,endpoint:"https://inline.invalid/api",request:{model:"inline-model"}}')
SF_TEST_PROVIDER_DELAY=0 SF_TEST_PROVIDER_REQUEST="$tmp/inline-request.json" \
  zsh -f "$entry" request -m "$inline_model" <"$session" >/dev/null
jq -e '.request == {model:"inline-model"} and .endpoint == "https://inline.invalid/api" and
  (has("config") | not)' "$tmp/inline-request.json" >/dev/null

# Invalid overrides fail without invoking a provider or falling back.
typeset invalid_model
for invalid_model in missing '{"request":{"model":"incomplete"}}' '{' \
    '{"provider":4}' $'bad\nname'; do
  if SF_TEST_PROVIDER_REQUEST="$tmp/rejected-request.json" \
      zsh -f "$entry" request --model "$invalid_model" \
      <"$session" >/dev/null 2>&1; then
    fail "request accepted invalid model: $invalid_model"
  fi
  [[ ! -e $tmp/rejected-request.json ]] || fail 'invalid model invoked a provider'
done

# Omitted provider configuration stays absent from the request.
jq -c 'if .type == "session" then del(.model.config) else . end' \
  "$session" >"$tmp/no-config.jsonl"
SF_TEST_PROVIDER_DELAY=0 SF_TEST_PROVIDER_REQUEST="$tmp/no-config-request.json" \
  zsh -f "$entry" request <"$tmp/no-config.jsonl" >/dev/null
jq -e 'has("config") | not' "$tmp/no-config-request.json" >/dev/null

# Provider execution follows the session cwd, not the command's cwd.
typeset cwd_provider="$tmp/cwd-provider/run" cwd_session="$tmp/cwd-session.jsonl"
mkdir -p "${cwd_provider:h}" "$tmp/project"
cat >"$cwd_provider" <<EOF
#!/usr/bin/env zsh
pwd -P >"$tmp/provider-cwd"
exec "$SF_TEST_PROVIDER"
EOF
chmod +x "$cwd_provider"
jq -c --arg provider "${cwd_provider:h}" '
  if .type == "session" then .cwd="~/project" | .model.provider=$provider else . end
' \
  "$session" >"$cwd_session"
HOME="$tmp" SF_TEST_PROVIDER_DELAY=0 zsh -f "$entry" request \
  <"$cwd_session" >/dev/null || fail 'home-relative request failed'
assert_equal "${tmp:A}/project" "$(<"$tmp/provider-cwd")" 'provider ran outside the session cwd'

# jq modules resolve from the installation root.
mkdir -p "$tmp/lib"
print -r -- 'def canonical_request(:' >"$tmp/lib/provider.jq"
(
  builtin cd -- "$tmp"
  response=$(SF_TEST_PROVIDER_DELAY=0 zsh -f "$entry" request <session.jsonl)
  jq -e '.content == [{type:"text",text:"composed request\n"}]' \
    <<<"$response" >/dev/null
  assert_equal "$tmp" "$PWD"
)

cp "$session" "$tmp/invalid-transition.jsonl"
print -r -- '{"type":"user","content":[{"type":"text","text":"duplicate"}]}' \
  >>"$tmp/invalid-transition.jsonl"
zsh -f "$entry" request <"$tmp/invalid-transition.jsonl" >/dev/null 2>&1 &&
  fail 'request accepted an invalid record transition'

# Hook context cannot place NUL in a projected user message.
{
  sed '$d' "$session"
  print -r -- '{"type":"hook_result","lifecycle":"stop","id":"1","model_text":"bad\u0000text"}'
  tail -n 1 "$session"
} >"$tmp/nul-context.jsonl"
zsh -f "$entry" request <"$tmp/nul-context.jsonl" >/dev/null 2>&1 &&
  fail 'request accepted NUL in projected hook context'

{
  sed '$d' "$session"
  tail -n 1 "$session" | jq -c '.content[0].text = "error"'
} >"$tmp/failing.jsonl"
SF_TEST_PROVIDER_DELAY=0 zsh -f "$entry" request <"$tmp/failing.jsonl" \
  >/dev/null 2>"$tmp/provider-error" && fail 'request accepted provider failure'
[[ $(<"$tmp/provider-error") == *'test provider failure'* ]] ||
  fail 'request hid the provider error'

# Reject invalid provider event streams without exposing partial output.
typeset invalid_provider="$tmp/invalid-provider/run" invalid_session="$tmp/invalid-session.jsonl"
mkdir -p "${invalid_provider:h}"
cat >"$invalid_provider" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- '{"type":"_assistant_message_delta","text":"partial"}'
case $SF_TEST_INVALID_STREAM in
  malformed) print -r -- '{' ;;
  late)
    print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"partial"}]}'
    print -r -- '{"type":"_assistant_message_delta","text":"late"}'
    ;;
  response)
    print -r -- '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"partial"}]}'
    ;;
esac
ZSH
chmod +x "$invalid_provider"
{
  IFS= read -r header
  jq -c --arg provider "${invalid_provider:h}" '.model.provider = $provider' <<<"$header"
  cat
} <"$session" >"$invalid_session"
typeset invalid_mode
for invalid_mode in malformed late response; do
  if SF_TEST_INVALID_STREAM=$invalid_mode zsh -f "$entry" request \
      <"$invalid_session" >"$tmp/invalid-$invalid_mode.out" \
      2>"$tmp/invalid-$invalid_mode.err"; then
    fail "request accepted $invalid_mode provider output"
  fi
  [[ ! -s "$tmp/invalid-$invalid_mode.out" ]] ||
    fail "request exposed $invalid_mode provider output"
  [[ $(<"$tmp/invalid-$invalid_mode.err") == *'provider emitted an invalid event stream'* ]] ||
    fail "request misreported $invalid_mode provider output"
done
