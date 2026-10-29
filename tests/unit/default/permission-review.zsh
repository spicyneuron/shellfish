#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp permission-review

typeset hook="$ROOT/share/hooks/sandbox-approver"
typeset session="$tmp/review.jsonl" control="$tmp/control.json"
typeset backend="$tmp/backend" captured="$tmp/permission-review.jsonl" mode="$tmp/mode"
typeset provider="$tmp/request.json"
typeset request before
integer hook_status=0

mkdir -p "$backend"
cat >"$backend/run" <<'ZSH'
#!/usr/bin/env zsh
cat >"$SF_TEST_REQUEST" || exit
[[ $(<"$SF_TEST_MODE") != failure ]] || exit 1
text=$(<"$SF_TEST_MODE")
[[ $text != valid ]] || text=$' \n{"risk":"medium","authorization":"high","reason":"Explicitly authorized."}\n'
jq -cn --arg text "$text" \
  '{type:"assistant",stop:"end",content:[{type:"reasoning",text:"review"},{type:"text",text:$text}]}'
ZSH
chmod +x "$backend/run"

sf_test_frozen_profile
SF_TEST_MODEL=$(jq -c --arg adapter "$backend" '
  .adapter=$adapter | .context_window=20000 | .request += {max_tokens:5000,temperature:0.2,
    response_schema:{type:"object",properties:{unexpected:{type:"string"}}}} |
  .config={http_timeout:120,http_stall:30,insecure_tls:false}
' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c --arg hook "$hook" '
  .hooks=[$hook] | .system=[{text:"fixed system"}]
' <<<"$SF_TEST_PROFILE")
sf_test_session "$session"
sf_session_append "$session" '{"type":"hook_result","lifecycle":"session_start","id":"1","model_text":"<context script=\"project/instructions\">\nstartup constraint\n</context>"}'
sf_session_append "$session" '{"type":"user","content":[{"type":"text","text":"opening request"}]}'
sf_session_append "$session" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"opening answer"}]}'
sf_session_append "$session" '{"type":"hook_result","lifecycle":"stop","id":"2","model_text":"retry constraint","action":"deny"}'
sf_session_append "$session" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"revised answer"}]}'
sf_session_append "$session" '{"type":"user","content":[{"type":"text","text":"run the local setup"}]}'
sf_session_append "$session" '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"I will inspect it."},{"type":"tool_call","id":"call_6","name":"shell","input":{"command":"inspect"}}]}'
sf_session_append "$session" '{"type":"tool_result","id":"call_6","name":"shell","input":{"command":"inspect"},"exit_code":0,"model_text":"inspection"}'
sf_session_append "$session" '{"type":"assistant","stop":"tool_calls","content":[{"type":"reasoning","text":"private","opaque":{"secret":"value"}},{"type":"text","text":"I will run it."},{"type":"tool_call","id":"call_7","name":"shell","input":{"command":"setup","sandbox_bypass_request":{"reason":"needed"}}}]}'
sf_session_append "$session" '{"type":"hook_result","lifecycle":"permission_request","id":"3","model_text":"permission context"}'
assert_canonical_session "$session"
request='{"tool_input":{"command":"setup","sandbox_bypass_request":{"reason":"needed"}}}'

# The decision goes to fd 3 and its reason to the user on stderr.
run_review() {
  print -r -- "$1" >"$mode"
  rm -f -- "$captured" "$provider"
  hook_status=0
  SF_TEST_REQUEST="$provider" SF_TEST_MODE="$mode" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$session" \
    SHELLFISH_TURN_STATE="$tmp" SHELLFISH_TURN_ID=6 \
    zsh -f "$hook/run" shell call_7 \
    3>"$tmp/lines" 2>|"$tmp/user" <<<"$request" || hook_status=$?
  jq -c -s last "$tmp/lines" >|"$control"
}

before=$(shasum <"$session")
run_review valid
(( hook_status == 0 )) || fail 'permission review did not resolve the request'
jq -e . "$control" >/dev/null || { cat "$control" >&2; fail 'permission review returned invalid control'; }
jq -e '
  .action == "allow" and (has("reason") | not) and
  .state_update[0].name == "permissions/6/call_7" and
  .state_update[0].value.reason == "Explicitly authorized." and
  (.state_update[0].value.content | fromjson) ==
    {risk:"medium",authorization:"high",reason:"Explicitly authorized."}
' "$control" >/dev/null || fail 'permission review returned the wrong decision'
jq -e '.on == "permission_request" and .user_preview_lines == "full"' \
  "$hook/manifest.json" >/dev/null &&
  assert_equal 'Approved: Explicitly authorized.' "$(<"$tmp/user")" ||
  fail 'permission review hid its decision reason'
jq -e -s --arg tool_input "$(jq -c '.tool_input' <<<"$request")" \
    --rawfile policy "$hook/review.md" '
  (.[1].content[0].text | fromjson) as $context |
  .[0].model.request.model == "test-model" and
  .[0].model.config == {http_timeout:120,http_stall:30,insecure_tls:false} and
  .[0].model.request.max_tokens == 5000 and
  .[0].model.request.temperature == 0.2 and
  .[0].profile.tools == [] and
  .[0].profile.hooks == [] and
  .[0].profile.system == [{text:($policy | rtrimstr("\n"))}] and
  [.[].type] == ["session","user"] and
  $context.system_message == "fixed system" and
  $context.startup_context.content[0].text ==
    "<hook name=\"session_start\">\n<context script=\"project/instructions\">\nstartup constraint\n</context>\n</hook>\n\nopening request" and
  $context.target_tool_call == {type:"tool_call",id:"call_7",name:"shell",input:($tool_input | fromjson)} and
  ($context.recent_timeline | map(.type)) ==
    ["assistant","user","assistant","user","assistant","tool_call","tool_result","user","assistant"] and
  ($context.recent_timeline[1].content[0].text | contains("retry constraint")) and
  ($context.recent_timeline[-2].content[0].text | contains("permission context")) and
  ($context | tostring | contains("private") | not) and
  ($context | tostring | contains("secret") | not)
' "$captured" >/dev/null || fail 'permission review projected the wrong transcript'
jq -e '.request.model == "test-model" and .request.max_output_tokens == 4096 and
  .request.response_schema.additionalProperties == false and .request.temperature == 0.2 and
  (.request.response_schema.properties | keys) == ["authorization","reason","risk"] and
  .config == {http_timeout:120,http_stall:30,insecure_tls:false} and .tools == []
' "$provider" >/dev/null || fail 'review settings did not reach the adapter'
assert_canonical_session "$captured"
assert_equal "$before" "$(shasum <"$session")" 'review changed the parent session'

typeset parent_session=$session
session="$tmp/default-review.jsonl"
jq -c 'if .type == "session" then del(.model.config) else . end' \
  "$parent_session" >"$session"
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null
jq -e 'has("config") | not' "$provider" >/dev/null ||
  fail 'review injected adapter configuration'
session=$parent_session

# An empty review configuration keeps the inherited model.
session="$tmp/empty-review.jsonl"
jq -c 'if .type == "session" then .profile.config["sandbox-approver"]={} else . end' \
  "$parent_session" >"$session"
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null
jq -e '.request.model == "test-model"' "$provider" >/dev/null

# A named review model replaces the complete model without touching the parent.
mkdir -p "$SHELLFISH_DIR/models/review/adapter" "$SHELLFISH_DIR/profiles"
ln -s "$backend/run" "$SHELLFISH_DIR/models/review/adapter/run"
print -r -- '{"hooks":["missing"]}' >"$SHELLFISH_DIR/profiles/default.jsonc"
cat >"$SHELLFISH_DIR/models/review/fast.v1.jsonc" <<'JSON'
{
  "adapter": "./adapter",
  "endpoint": "https://review.invalid/api",
  "context_window": 12000,
  "config": {"http_timeout": 60},
  "request": {"model": "review-model", "max_completion_tokens": 2048,
    "response_schema": {"properties": {"unexpected": {"type": "string"}}}}
}
JSON
session="$tmp/configured-review.jsonl"
jq -c 'if .type == "session" then .profile.config["sandbox-approver"].model="review/fast.v1" else . end' \
  "$parent_session" >"$session"
before=$(shasum <"$session")
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null
jq -e '.endpoint == "https://review.invalid/api" and .config == {http_timeout:60} and
  .request.model == "review-model" and .request.max_output_tokens == 4096 and
  .request.response_schema.additionalProperties == false and
  (.request.response_schema.properties | keys) == ["authorization","reason","risk"] and
  (.request | has("temperature") | not)
' "$provider" >/dev/null || fail 'review did not use the complete configured model'
assert_canonical_session "$captured"
assert_equal "$before" "$(shasum <"$session")" 'configured review changed the parent session'
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null || fail 'repeated model resolution failed'

# Reviews use a fixed input budget and read model files on every request.
sed -e 's/12000/4097/' -e 's/review-model/updated-model/' \
  "$SHELLFISH_DIR/models/review/fast.v1.jsonc" >"$tmp/small-model.jsonc"
mv "$tmp/small-model.jsonc" "$SHELLFISH_DIR/models/review/fast.v1.jsonc"
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null || fail 'review used model-sized input budgeting'
jq -e '.request.model == "updated-model"' "$provider" >/dev/null ||
  fail 'review did not reread its model file'

typeset review_config
for review_config in 'null' 'false' '[]' '{"unknown":true}' \
    '{"model":null}' '{"model":4}' '{"model":""}' '{"model":"../fast"}'; do
  jq -c --argjson config "$review_config" '
    if .type == "session" then .profile.config["sandbox-approver"]=$config else . end
  ' "$parent_session" >"$session"
  run_review valid
  jq -e '(has("action") | not) and
    .state_update[0].value.reason == "Permission review has invalid configuration."' \
    "$control" >/dev/null || fail "review accepted invalid configuration: $review_config"
  [[ ! -e $captured ]] || fail 'invalid review configuration called the provider'
done
jq -c 'if .type == "session" then .profile.config["sandbox-approver"].model="missing" else . end' \
  "$parent_session" >"$session"
run_review valid
jq -e '(has("action") | not) and
  .state_update[0].value.reason == "Permission review provider request failed."' \
  "$control" >/dev/null || fail 'missing review model did not defer'
[[ ! -e $provider ]] || fail 'missing review model fell back to the parent model'
print -r -- '{"adapter":' >"$SHELLFISH_DIR/models/missing.jsonc"
run_review valid
jq -e '(has("action") | not) and
  .state_update[0].value.reason == "Permission review provider request failed."' \
  "$control" >/dev/null || fail 'malformed review model did not defer'
[[ ! -e $provider ]] || fail 'malformed review model called the provider'
session=$parent_session

run_review failure
(( hook_status == 0 )) || fail 'provider failure failed the hook'
jq -e '(has("action") | not) and
  .state_update[0].value == {content:null,reason:"Permission review provider request failed."}
' "$control" >/dev/null || fail 'provider failure did not defer to the user'
assert_equal 'Review failed, asking the user: Permission review provider request failed.' \
  "$(<"$tmp/user")"

run_review '{"risk":"high","authorization":"unknown","reason":"Not authorized."}'
(( hook_status == 0 )) || fail 'unknown authorization did not resolve'
jq -e '.action == "deny" and .reason == "Not authorized." and
  (.state_update[0].value.content | fromjson).authorization == "unknown"
' "$control" >/dev/null || fail 'unknown authorization was not denied'
