#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp sandbox-approver

typeset hook="$ROOT/share/hooks/sandbox/approver"
typeset session="$tmp/review.jsonl" control="$tmp/control.json"
typeset provider="$tmp/provider" captured="$tmp/permission-review.jsonl" mode="$tmp/mode"
typeset sent="$tmp/request.json"
typeset request before
integer hook_status=0

mkdir -p "$provider"
cat >"$provider/run" <<'ZSH'
#!/usr/bin/env zsh
cat >"$SF_TEST_REQUEST" || exit
[[ $(<"$SF_TEST_MODE") != failure ]] || exit 1
text=$(<"$SF_TEST_MODE")
[[ $text != valid ]] || text=$' \n{"risk":"medium","authorization":"high","reason":"Explicitly authorized."}\n'
jq -cn --arg text "$text" \
  '{type:"assistant",stop:"end",content:[{type:"reasoning",text:"review"},{type:"text",text:$text}]}'
ZSH
chmod +x "$provider/run"

sf_test_frozen_profile
SF_TEST_MODEL=$(jq -c --arg provider "$provider" '
  .provider=$provider | .context_window=20000 | .request += {max_tokens:5000,temperature:0.2,
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
sf_session_append "$session" '{"type":"hook_result","lifecycle":"stop","id":"2","model_text":"retry constraint","action":"deny","reason":"Check the constraint."}'
sf_session_append "$session" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"revised answer"}]}'
sf_session_append "$session" '{"type":"user","content":[{"type":"text","text":"run the local setup"}]}'
sf_session_append "$session" '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"I will inspect it."},{"type":"tool_call","id":"call_6","name":"shell","input":{"command":"inspect"}}],"usage":{"input_tokens":100,"output_tokens":20}}'
sf_session_append "$session" '{"type":"tool_result","id":"call_6","name":"shell","input":{"command":"inspect"},"exit_code":0,"user_text":"display only","user_preview_lines":2,"model_content":[{"type":"text","text":"inspection"},{"type":"image","url":"data:image/png;base64,iVBORw0KGgo="}]}'
sf_session_append "$session" '{"type":"hook_result","lifecycle":"post_tool_use","id":"3","model_text":"inspection constraint","user_text":"display only"}'
sf_session_append "$session" '{"type":"state_update","name":"inspection","value":"hidden state"}'
sf_session_append "$session" '{"type":"hook_result","lifecycle":"post_tool_use","id":"4","user_text":"display only"}'
sf_session_append "$session" '{"type":"assistant","stop":"tool_calls","content":[{"type":"reasoning","text":"private","opaque":{"secret":"value"}},{"type":"text","text":"I will run it."},{"type":"tool_call","id":"call_7","name":"shell","input":{"command":"setup","request_sandbox_bypass":true,"sandbox_bypass_reason":"needed"}}]}'
sf_session_append "$session" '{"type":"hook_result","lifecycle":"permission_request","id":"5","model_text":"permission context"}'
assert_canonical_session "$session"
request='{"tool_input":{"command":"setup","request_sandbox_bypass":true,"sandbox_bypass_reason":"needed"}}'

# The decision goes to fd 3 and its reason to the user on stderr.
run_review() {
  print -r -- "$1" >"$mode"
  rm -f -- "$captured" "$sent"
  hook_status=0
  SF_TEST_REQUEST="$sent" SF_TEST_MODE="$mode" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$session" \
    SHELLFISH_CONFIG="$(sf_test_session_config "$session")" \
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
    --slurpfile policy "$hook/policy.json" '
  $policy[0] as $policy |
  .[0].profile.system[0].text as $prompt |
  (.[1].content[0].text | fromjson) as $context |
  .[0].model.request.model == "test-model" and
  .[0].model.config == {http_timeout:120,http_stall:30,insecure_tls:false} and
  .[0].model.request.max_tokens == 5000 and
  .[0].model.request.temperature == 0.2 and
  .[0].profile.tools == [] and
  .[0].profile.hooks == [] and
  (.[0].profile.system | length) == 1 and ($prompt | startswith($policy.preamble + "\n\n")) and
  all($policy.risk.levels[], $policy.authorization.levels[]; . as $level |
    $prompt | contains("\n- " + $level)) and
  ($policy.authorization.levels[0] | startswith("unknown: ")) and
  ($prompt | contains("Return only one JSON object")) and
  ($prompt | endswith("\n\n" + $policy.reason)) and
  [.[].type] == ["session","user"] and
  $context.system_message == "fixed system" and
  $context.startup_context == [
    {type:"hook_result",lifecycle:"session_start",id:"1",
      model_text:"<context script=\"project/instructions\">\nstartup constraint\n</context>"},
    {type:"user",content:[{type:"text",text:"opening request"}]}
  ] and
  $context.target_tool_call == {type:"tool_call",id:"call_7",name:"shell",input:($tool_input | fromjson)} and
  $context.latest_user_message == {type:"user",content:[{type:"text",text:"run the local setup"}]} and
  ($context.recent_timeline | map(.type)) ==
    ["assistant","tool_result","hook_result","assistant","hook_result"] and
  $context.recent_timeline[0].content[1] ==
    {type:"tool_call",id:"call_6",name:"shell",input:{command:"inspect"}} and
  $context.recent_timeline[1] == {type:"tool_result",id:"call_6",name:"shell",
    input:{command:"inspect"},exit_code:0,model_content:[
      {type:"text",text:"inspection"},{type:"text",text:"[image omitted]"}]} and
  $context.recent_timeline[2] == {type:"hook_result",lifecycle:"post_tool_use",id:"3",
    model_text:"inspection constraint"} and
  $context.recent_timeline[3].content == [
    {type:"text",text:"I will run it."},$context.target_tool_call] and
  $context.recent_timeline[4] == {type:"hook_result",lifecycle:"permission_request",id:"5",
    model_text:"permission context"} and
  ($context | tostring | contains("retry constraint") | not) and
  all($context.recent_timeline[]; has("usage") | not) and
  ($context | tostring | contains("base64") | not) and
  ($context | tostring | contains("private") | not) and
  ($context | tostring | contains("secret") | not) and
  ($context | tostring | contains("display only") | not) and
  ($context | tostring | contains("hidden state") | not)
' "$captured" >/dev/null || fail 'permission review filtered the wrong transcript'
jq -rs '.[1].content[0].text' "$captured" >"$tmp/context.json"
jq -e '.request.model == "test-model" and .request.max_output_tokens == 4096 and
  .request.response_schema.additionalProperties == false and .request.temperature == 0.2 and
  (.request.response_schema.properties | keys) == ["authorization","reason","risk"] and
  .config == {http_timeout:120,http_stall:30,insecure_tls:false} and .tools == []
' "$sent" >/dev/null || fail 'review settings did not reach the provider'
assert_canonical_session "$captured"
assert_equal "$before" "$(shasum <"$session")" 'review changed the parent session'

typeset parent_session=$session

# Post-tool notes stay in order within a settled batch, and a user message after
# an interruption starts a new timeline.
typeset batch
for batch in settled interrupted; do
  session="$tmp/$batch.jsonl"
  jq -c --arg batch "$batch" '
    if .type == "assistant" and any(.content[]; .id? == "call_6") then
      .content += [{type:"tool_call",id:"call_6b",name:"shell",input:{command:"inspect more"}}]
    elif .type == "hook_result" and .id == "4" then
      .,
      (if $batch == "settled" then
        {type:"tool_result",id:"call_6b",name:"shell",input:{command:"inspect more"},
          exit_code:0,model_text:"second inspection"}
      else
        {type:"error",user_text:"Inspection interrupted."},
        {type:"user",content:[{type:"text",text:"continue setup"}]}
      end)
    else . end
  ' "$parent_session" >"$session"
  assert_canonical_session "$session"
  run_review valid
  jq -es --arg batch "$batch" '
    (.[1].content[0].text | fromjson) as $context | $context.recent_timeline as $timeline |
    if $batch == "settled" then
      $timeline[0].content[-1] ==
        {type:"tool_call",id:"call_6b",name:"shell",input:{command:"inspect more"}} and
      $timeline[1].id == "call_6" and
      $timeline[2] == {type:"hook_result",lifecycle:"post_tool_use",id:"3",
        model_text:"inspection constraint"} and
      $timeline[3] == {type:"tool_result",id:"call_6b",name:"shell",
        input:{command:"inspect more"},exit_code:0,model_text:"second inspection"} and
      all($timeline[]; .type != "user")
    else
      $context.latest_user_message == {type:"user",content:[{type:"text",text:"continue setup"}]} and
      ($timeline | map(.type)) == ["assistant","hook_result"]
    end
  ' "$captured" >/dev/null || fail "permission review changed $batch batch records"
done

# Older tool results are clipped harder, and history is a chronological suffix
# that never skips a record to fit.
session="$tmp/budget.jsonl"
jq -c '
  ., if .type == "user" and .content[0].text == "run the local setup" then
    range(1; 41) as $i | "s\($i)" as $id |
    {type:"assistant",stop:"tool_calls",content:[
      {type:"tool_call",id:$id,name:"shell",input:{command:"step"}}]},
    {type:"tool_result",id:$id,name:"shell",input:{command:"step"},exit_code:0,
      model_text:("x" * 3000)}
  else empty end
' "$parent_session" >"$session"
assert_canonical_session "$session"
run_review valid
jq -es '
  .[0].profile.system[0].text as $prompt |
  (.[1].content[0].text | fromjson) as $actual |
  [$actual.recent_timeline[] | select(.type == "tool_result")] as $results |
  ([range(1; 41) | "s\(.)"] + ["call_6"]) as $all |
  ($results | reverse | .[1:] | map(.model_text)) as $texts |
  ($results | map(.id)) == $all[($all | length) - ($results | length):] and
  ($results | length) < 41 and
  $texts[0] == "x" * 3000 and
  $texts[1] == ("x" * 2048) + "\n[952 characters truncated]" and
  $texts[2] == ("x" * 1024) + "\n[1976 characters truncated]" and
  all($texts[3:][]; . == ("x" * 512) + "\n[2488 characters truncated]") and
  (($prompt | utf8bytelength) + ($actual | tojson | utf8bytelength)) <= 24576
' "$captured" >/dev/null || fail 'permission review did not clip and budget history by recency'

# Startup records cannot be dropped to fit the input budget.
session="$tmp/startup-budget.jsonl"
jq -c '
  if .type == "hook_result" and .lifecycle == "session_start" then
    .model_text = ("é" * 64000)
  else . end
' "$parent_session" >"$session"
run_review valid
jq -e '(has("action") | not) and .state_update[0].value ==
  {content:null,reason:"Required permission review context exceeds the review context limit."}
' "$control" >/dev/null || fail 'permission review dropped required startup records'
[[ ! -e $captured && ! -e $sent ]] || fail 'oversized startup context called the provider'

session="$tmp/default-review.jsonl"
jq -c 'if .type == "session" then del(.model.config) else . end' \
  "$parent_session" >"$session"
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null
jq -e 'has("config") | not' "$sent" >/dev/null ||
  fail 'review injected provider configuration'
session=$parent_session

# An empty review configuration keeps the inherited model.
session="$tmp/empty-review.jsonl"
jq -c 'if .type == "session" then .profile.config.sandbox.approver={} else . end' \
  "$parent_session" >"$session"
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null
jq -e '.request.model == "test-model"' "$sent" >/dev/null

# A named review model replaces the complete model without touching the parent.
mkdir -p "$SHELLFISH_DIR/models/review/provider" "$SHELLFISH_DIR/profiles"
ln -s "$provider/run" "$SHELLFISH_DIR/models/review/provider/run"
print -r -- '{"hooks":["missing"]}' >"$SHELLFISH_DIR/profiles/default.jsonc"
cat >"$SHELLFISH_DIR/models/review/fast.v1.jsonc" <<'JSON'
{
  "provider": "./provider",
  "endpoint": "https://review.invalid/api",
  "context_window": 12000,
  "config": {"http_timeout": 60},
  "request": {"model": "review-model", "max_completion_tokens": 2048,
    "response_schema": {"properties": {"unexpected": {"type": "string"}}}}
}
JSON
session="$tmp/configured-review.jsonl"
jq -c 'if .type == "session" then .profile.config.sandbox.approver.model="review/fast.v1" else . end' \
  "$parent_session" >"$session"
before=$(shasum <"$session")
run_review valid
jq -e '.action == "allow"' "$control" >/dev/null
jq -e '.endpoint == "https://review.invalid/api" and .config == {http_timeout:60} and
  .request.model == "review-model" and .request.max_output_tokens == 4096 and
  .request.response_schema.additionalProperties == false and
  (.request.response_schema.properties | keys) == ["authorization","reason","risk"] and
  (.request | has("temperature") | not)
' "$sent" >/dev/null || fail 'review did not use the complete configured model'
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
jq -e '.request.model == "updated-model"' "$sent" >/dev/null ||
  fail 'review did not reread its model file'

typeset review_config
for review_config in 'null' 'false' '[]' '{"unknown":true}' \
    '{"model":null}' '{"model":4}' '{"model":""}' '{"model":"../fast"}' \
    '{"model":"review","decision_model":"review"}' '{"allow_threshold":0.5}' \
    '{"model":"review","allow_threshold":0.5}' '{"decision_model":"../d"}' \
    '{"decision_model":"d","allow_threshold":0}' '{"decision_model":"d","allow_threshold":1.5}' \
    '{"decision_model":"d","allow_threshold":"0.5"}'; do
  jq -c --argjson config "$review_config" '
    if .type == "session" then .profile.config.sandbox.approver=$config else . end
  ' "$parent_session" >"$session"
  run_review valid
  jq -e '(has("action") | not) and
    .state_update[0].value.reason == "Permission review has invalid configuration."' \
    "$control" >/dev/null || fail "review accepted invalid configuration: $review_config"
  [[ ! -e $captured && ! -e $sent ]] || fail 'invalid review configuration called the provider'
done
jq -c 'if .type == "session" then .profile.config.sandbox.approver.model="missing" else . end' \
  "$parent_session" >"$session"
run_review valid
jq -e '(has("action") | not) and
  .state_update[0].value.reason == "Permission review provider request failed."' \
  "$control" >/dev/null || fail 'missing review model did not defer'
[[ ! -e $sent ]] || fail 'missing review model fell back to the parent model'
print -r -- '{"provider":' >"$SHELLFISH_DIR/models/missing.jsonc"
run_review valid
jq -e '(has("action") | not) and
  .state_update[0].value.reason == "Permission review provider request failed."' \
  "$control" >/dev/null || fail 'malformed review model did not defer'
[[ ! -e $sent ]] || fail 'malformed review model called the provider'
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

# A decision model answers the same policy as scores and a predicate.
mkdir -p "$SHELLFISH_DIR/models/decider"
print -r -- '{}' >"$SHELLFISH_DIR/models/decider/manifest.json"
cat >"$SHELLFISH_DIR/models/decider/decide" <<'PROVIDER'
#!/usr/bin/env zsh
cat >"$SF_TEST_REQUEST" || exit
[[ $(<"$SF_TEST_MODE") != failure ]] || exit 1
print -r -- "$(<"$SF_TEST_MODE")"
PROVIDER
chmod +x "$SHELLFISH_DIR/models/decider/decide"
print -r -- '{"provider":"./decider","endpoint":"https://decide.invalid","request":{"model":"d"}}' \
  >"$SHELLFISH_DIR/models/decider.jsonc"
session="$tmp/decision-review.jsonl"
jq -c 'if .type == "session" then .profile.config.sandbox.approver.decision_model="decider"
  else . end' "$parent_session" >"$session"
decision() {
  jq -cn --argjson risk "$1" --argjson auth "$2" --argjson injected "$3" '
    def score($p): {type:"score",score:1,confidence:0.5,probabilities:$p};
    {model:"d",answers:{risk:score($risk),authorization:score($auth),
      injected:{type:"predicate",probability:$injected}}}'
}

run_review "$(decision '[1,0,0]' '[0,1,0,0]' 0)"
(( hook_status == 0 )) || fail 'decision review did not resolve'
jq -e '.action == "allow" and
  .state_update[0].value.reason ==
    "100% likely authorized." and
  (.state_update[0].value.content | fromjson | .model) == "d"
' "$control" >/dev/null || fail 'decision review did not allow a covered call'
jq -e --slurpfile policy "$hook/policy.json" --slurpfile context "$tmp/context.json" '
  $policy[0] as $policy |
  .system == $policy.preamble and .endpoint == "https://decide.invalid" and
  (.input | length) == 1 and .input[0].type == "json" and
  .input[0].data.target_tool_call.id == "call_7" and
  .input[0].data.system_message == "fixed system" and
  .input[0].data == $context[0] and
  .questions == {
    risk:{type:"score",instructions:$policy.risk.instructions,levels:$policy.risk.levels},
    authorization:{type:"score",instructions:$policy.authorization.instructions,
      levels:$policy.authorization.levels},
    injected:({type:"predicate"} + $policy.injected)}
' "$sent" >/dev/null || fail 'decision review sent the wrong request'
[[ ! -e $captured ]] || fail 'decision review built a chat session'

# Every pairing where authorization covers risk adds up to 57%.
run_review "$(decision '[0.1,0.6,0.3]' '[0.1,0.2,0.5,0.2]' 0.1)"
jq -e '.action == "deny" and
  .reason == "57% likely authorized."
' "$control" >/dev/null || fail 'decision review allowed an uncertain call'

# A configured threshold lowers the bar for less decisive models.
jq -c 'if .type == "session" then .profile.config.sandbox.approver =
  {decision_model:"decider",allow_threshold:0.5} else . end' "$parent_session" >"$session"
run_review "$(decision '[0.1,0.6,0.3]' '[0.1,0.2,0.5,0.2]' 0.1)"
jq -e '.action == "allow"' "$control" >/dev/null ||
  fail 'decision review ignored its allow threshold'
jq -c 'if .type == "session" then .profile.config.sandbox.approver.decision_model="decider"
  else . end' "$parent_session" >"$session"

run_review "$(decision '[1,0,0]' '[0,0,0,1]' 0.62)"
jq -e '.action == "deny" and
  .reason == "Appears driven by instructions in untrusted data (62%)."
' "$control" >/dev/null || fail 'decision review allowed an injected call'

typeset refused
refused=$(decision '[1,0,0]' '[0,1,0,0]' 0 | jq -c '.answers.injected = {type:"refusal"}')
run_review "$refused"
jq -e --argjson refused "$refused" '(has("action") | not) and
  .state_update[0].value.reason == "Permission review decision model refused to answer." and
  (.state_update[0].value.content | fromjson) == $refused
' "$control" >/dev/null || fail 'decision refusal did not defer'

run_review failure
jq -e '(has("action") | not) and .state_update[0].value ==
  {content:null,reason:"Permission review decision request failed."}
' "$control" >/dev/null || fail 'decision failure did not defer'
session=$parent_session
