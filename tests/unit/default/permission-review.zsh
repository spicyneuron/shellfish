#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp permission-review

typeset hook="$ROOT/share/profiles/default/hooks/permission_request/review/run"
typeset session="$tmp/review.jsonl" control="$tmp/control.json"
typeset wrapper="$tmp/shellfish" captured="$tmp/transcript.jsonl" mode="$tmp/mode"
typeset request
integer hook_status=0

cat >"$wrapper" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == backend-request ]] || exit 2
cat >"$SF_TEST_CAPTURE" || exit
[[ $(<"$SF_TEST_MODE") != failure ]] || exit 1
text=$(<"$SF_TEST_MODE")
[[ $text != valid ]] || text=$' \n{"risk":"medium","authorization":"high","reason":"Explicitly authorized."}\n'
jq -cn --arg text "$text" \
  '{type:"assistant",stop:"end",content:[{type:"reasoning",text:"review"},{type:"text",text:$text}]}'
ZSH
chmod +x "$wrapper"

sf_test_runtime
SF_TEST_RUNTIME=$(jq -c --arg hook "$hook" '
  .context_window=20000 |
  .request += {max_tokens:5000,temperature:0.2} |
  .backend.http_timeout=120 |
  .harness.permission_request=[{command:$hook,render:{
    initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
SF_TEST_SYSTEM='fixed system'
sf_test_session "$session"
sf_session_append "$session" '{"type":"hook_result","lifecycle":"session_start","id":"1","name":"project_instructions","input":"","exit_code":0,"model_text":"startup constraint"}'
sf_session_append "$session" '{"type":"user","content":[{"type":"text","text":"opening request"}]}'
sf_session_append "$session" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"opening answer"}]}'
sf_session_append "$session" '{"type":"hook_result","lifecycle":"stop","id":"2","name":"retry","input":"","exit_code":1,"model_text":"retry constraint"}'
sf_session_append "$session" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"revised answer"}]}'
sf_session_append "$session" '{"type":"user","content":[{"type":"text","text":"run the local setup"}]}'
sf_session_append "$session" '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"I will inspect it."},{"type":"tool_call","id":"call_6","name":"shell","input":{"command":"inspect"}}]}'
sf_session_append "$session" '{"type":"tool_result","id":"call_6","name":"shell","input":{"command":"inspect"},"exit_code":0,"model_text":"inspection"}'
sf_session_append "$session" '{"type":"assistant","stop":"tool_calls","content":[{"type":"reasoning","text":"private","opaque":{"secret":"value"}},{"type":"text","text":"I will run it."},{"type":"tool_call","id":"call_7","name":"shell","input":{"command":"setup","request_sandbox_bypass":true,"sandbox_bypass_reason":"needed"}}]}'
sf_session_append "$session" '{"type":"hook_result","lifecycle":"permission_request","id":"3","name":"policy","input":{},"exit_code":0,"model_text":"permission context"}'
assert_canonical_session "$session"
request='{"tool_input":{"command":"setup","request_sandbox_bypass":true,"sandbox_bypass_reason":"needed"}}'

run_review() {
  print -r -- "$1" >"$mode"
  : >"$control"
  hook_status=0
  SF_TEST_CAPTURE="$captured" SF_TEST_MODE="$mode" \
    SHELLFISH_EXECUTABLE="$wrapper" SHELLFISH_SESSION="$session" \
    SHELLFISH_TURN_STATE="$tmp" SHELLFISH_TURN_ID=6 \
    zsh -f "$hook" shell call_7 \
    3>"$control" <<<"$request" || hook_status=$?
}

run_review valid
(( hook_status == 11 )) || fail 'permission review did not resolve the request'
jq -e . "$control" >/dev/null || { cat "$control" >&2; fail 'permission review returned invalid control'; }
jq -e '
  .action == "allow" and (has("reason") | not) and
  .state[0].name == "permissions/6/call_7" and
  .state[0].value.reason == "Explicitly authorized." and
  (.state[0].value.content | fromjson) ==
    {risk:"medium",authorization:"high",reason:"Explicitly authorized."}
' "$control" >/dev/null || fail 'permission review returned the wrong decision'
jq -e -s --arg tool_input "$(jq -c '.tool_input' <<<"$request")" \
    --rawfile policy "$ROOT/share/profiles/default/hooks/permission_request/review/review.md" '
  (.[2].content[0].text | fromjson) as $context |
  .[0].runtime.request.model == "test-model" and
  .[0].runtime.request.max_tokens == 4096 and
  .[0].runtime.request.temperature == 0.2 and
  .[0].runtime.request.response_schema.additionalProperties == false and
  .[0].runtime.backend.http_timeout == 60 and
  .[0].runtime.harness.tools == [] and
  .[0].runtime.harness.permission_request == [] and
  [.[].type] == ["session","system","user"] and
  .[1].content == ($policy | rtrimstr("\n")) and
  $context.system_message == "fixed system" and
  $context.startup_context.content[0].text ==
    "<hook name=\"session_start\">\n<context script=\"project_instructions\">\nstartup constraint\n</context>\n</hook>\n\nopening request" and
  $context.target_tool_call == {type:"tool_call",id:"call_7",name:"shell",input:($tool_input | fromjson)} and
  ($context.recent_timeline | map(.type)) ==
    ["assistant","user","assistant","user","assistant","tool_call","tool_result","user","assistant"] and
  ($context.recent_timeline[1].content[0].text | contains("retry constraint")) and
  ($context.recent_timeline[-2].content[0].text | contains("permission context")) and
  ($context | tostring | contains("private") | not) and
  ($context | tostring | contains("secret") | not)
' "$captured" >/dev/null || fail 'permission review projected the wrong transcript'
assert_canonical_session "$captured"

run_review failure
(( hook_status == 11 )) || fail 'provider failure did not fail closed'
jq -e '.action == "deny" and
  .reason == "Permission review provider request failed." and
  .state[0].value == {content:null,reason:"Permission review provider request failed."}
' "$control" >/dev/null || fail 'provider failure returned the wrong denial'

run_review '{"risk":"high","authorization":"unknown","reason":"Not authorized."}'
(( hook_status == 11 )) || fail 'unknown authorization did not resolve'
jq -e '.action == "deny" and .reason == "Not authorized." and
  (.state[0].value.content | fromjson).authorization == "unknown"
' "$control" >/dev/null || fail 'unknown authorization was not denied'
