#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-tool-contract
mkdir "$tmp/host-temp"
export TMPDIR="$tmp/host-temp" TMPPREFIX="$tmp/manifest-prefix"
sf_test_frozen_profile

# The bundled shell decodes multiline commands once, preserves exit status, and
# reports it in a footer.
typeset shell_tool="$ROOT/share/tools/shell/run"
assert_equal $'first\nsecond\n\nexit 0' "$(print -rn -- \
  '{"command":"print -r -- first; print -r -- second"}' | "$shell_tool")"
integer shell_status=0
print -rn -- '{"command":"exit 7"}' | "$shell_tool" >/dev/null || shell_status=$?
(( shell_status == 7 )) || fail 'shell tool changed the command exit status'
if print -rn -- '{"command":"true","extra":true}' | "$shell_tool" >/dev/null 2>&1; then
  fail 'shell tool accepted an unknown input field'
fi

sf_test_shell_tool '.environment=["TMPPREFIX"]'

# Tools use the host temp directory rather than a Shellfish-owned turn directory.
typeset temp_session="$tmp/tool-temp.jsonl" temp_stream="$tmp/tool-temp.stream"
sf_test_session "$temp_session"
SF_TEST_PROVIDER_TOOL_CALL=1 \
  SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- "$TMPDIR|$TMPPREFIX"' \
  sf_test_run temp "$temp_session" >"$temp_stream" || fail 'tool temp environment turn failed'
jq -eRn --arg expected "${TMPDIR:A}|${TMPDIR:A}/zsh" '
  [inputs | fromjson | select(.type == "tool_result")][0].model_text ==
    ($expected + "\nexit 0")
' <"$temp_stream" >/dev/null || fail 'tool did not receive the host temp environment'

# Hooks receive all .env values; tools receive only declared names.
typeset env_config="$SHELLFISH_DIR" env_hook="$tmp/env-hook" env_seen="$tmp/env-seen"
typeset env_session="$tmp/env.jsonl" env_stream="$tmp/env.stream" base_profile=$SF_TEST_PROFILE
typeset env_command='print -rn -- "${DECLARED-unset} ${UNDECLARED-unset} ${EXPORTED-unset} ${SHELLFISH_SHARE_DIR-unset}"'
mkdir -p "$env_config"
print -rl -- DECLARED=declared-file UNDECLARED=undeclared-file >"$env_config/.env"
sf_test_hook "$env_hook" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- "${UNDECLARED-unset} ${SHELLFISH_SHARE_DIR-unset}" >"$ENV_SEEN"
ZSH
export ENV_SEEN=$env_seen EXPORTED=exported
sf_test_shell_tool '.environment=["DECLARED"]'
sf_test_bind_hooks post_tool_use "$env_hook"
sf_test_session "$env_session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND=$env_command \
  sf_test_run env "$env_session" >"$env_stream" || fail 'tool environment turn failed'
jq -eRn --arg share "$SF_SHARE" '[inputs | fromjson | select(.type == "tool_result")][0].model_text ==
  ("declared-file unset exported " + $share + "\nexit 0")' <"$env_stream" >/dev/null ||
  fail 'unsandboxed tool did not receive .env with declared-name filtering'
assert_equal "undeclared-file $SF_SHARE" "$(<$env_seen)" \
  'hook did not receive .env values'
for manifest in '.environment=[]' 'del(.environment)'; do
  sf_test_shell_tool "$manifest"
  sf_test_session "$env_session"
  SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND=$env_command \
    sf_test_run env "$env_session" >"$env_stream" || fail 'empty tool environment turn failed'
  jq -eRn --arg share "$SF_SHARE" '[inputs | fromjson | select(.type == "tool_result")][0].model_text ==
    ("unset unset exported " + $share + "\nexit 0")' <"$env_stream" >/dev/null ||
    fail 'an unsandboxed tool without declarations received .env credentials'
  assert_equal "undeclared-file $SF_SHARE" "$(<$env_seen)" \
    'an empty tool environment changed hook inheritance'
done
SF_TEST_PROFILE=$base_profile

# Tool manifests are read on each run, so an edit after creation takes effect.
typeset live_session="$tmp/live-manifest.jsonl"
sf_test_session "$live_session"
sf_test_shell_tool '.environment=["TMPPREFIX"] | .description="edited after creation"'
SF_TEST_PROVIDER_REQUEST="$tmp/live-request.json" sf_test_run live "$live_session" >/dev/null ||
  fail 'live manifest turn failed'
jq -e '.tools[0].description | startswith("edited after creation")' \
  "$tmp/live-request.json" >/dev/null || fail 'tool manifest was not read live'
sf_test_shell_tool '.environment=["TMPPREFIX"]'

# A tool that opts out runs normally even when session sandboxing is enabled.
SF_TEST_PROFILE=$(jq -c '.sandbox.enabled=true' <<<"$SF_TEST_PROFILE")
sf_test_shell_tool '.sandbox=false | .allow_sandbox_bypass=false'
typeset opted_out_session="$tmp/opted-out.jsonl" opted_out_stream="$tmp/opted-out.stream"
sf_test_session "$opted_out_session"
SF_TEST_PROVIDER_TOOL_CALL=1 sf_test_run opted-out "$opted_out_session" >"$opted_out_stream" ||
  fail 'opted-out tool turn failed'
jq -eRn '[inputs | fromjson] as $events |
  all($events[]; has("sandbox_access") | not) and
  ($events | any(.type == "tool_result" and .exit_code == 0)) and
  ($events | any(.type == "_tool_permission_request") | not)
' <"$opted_out_stream" >/dev/null || fail 'opted-out tool was treated as a bypass'
assert_canonical_session "$opted_out_session"
SF_TEST_PROFILE=$base_profile
sf_test_shell_tool '.environment=["TMPPREFIX"]'

# Tool temp cannot redirect the next call's core-owned input write.
typeset input_target="$tmp/tool-input-target" input_session="$tmp/tool-input.jsonl"
typeset input_stream="$tmp/tool-input.stream"
sf_test_session "$input_session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COUNT=2 \
  SF_TEST_PROVIDER_TOOL_COMMAND="ln -sf ${(q)input_target} \"\$TMPDIR/input\"" \
  sf_test_run input "$input_session" >"$input_stream" || fail 'tool input isolation turn failed'
[[ ! -e $input_target ]] || fail 'tool temp redirected a later input write'

# Pre-tool denial refuses with its reason without reaching the later hook,
# preserves sibling calls, and still reaches post hooks.
typeset pre="$tmp/pre" later="$tmp/pre-later" post="$tmp/post"
typeset hook_dir="$tmp/hook-inputs" tool_marker="$tmp/tool-ran"
mkdir "$hook_dir"
sf_test_hook "$pre" '{"user_text":"${output.stderr}"}' <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$HOOK_DIR/pre-$id"
if [[ $id == call_1 ]]; then
  print -r -u3 -- '{"state_update":[{"name":"pre/call_1","value":true}],"action":"deny","reason":"pre denied"}'
  print -rn -- 'pre context'
  print -rn -u2 -- 'pre display'
fi
ZSH
sf_test_hook "$later" <<'ZSH'
#!/usr/bin/env zsh
id=$(jq -r '.tool_use_id')
print -r -- "$id" >>"$HOOK_DIR/later"
ZSH
sf_test_hook "$post" '{"user_text":"${output.stderr}"}' <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$HOOK_DIR/post-$id"
print -rn -u3 -- "{\"state_update\":[{\"name\":\"post/$id\",\"value\":true}]}"
print -rn -u2 -- "post $id"
ZSH
export HOOK_DIR=$hook_dir TOOL_MARKER=$tool_marker
sf_test_bind_hooks pre_tool_use "$pre" "$later"
sf_test_bind_hooks post_tool_use "$post"
typeset session="$tmp/denied.jsonl" stream="$tmp/denied.stream"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COUNT=2 \
  SF_TEST_PROVIDER_TOOL_COMMAND="print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  sf_test_run tools "$session" >"$stream" || fail 'pre-tool denial turn failed'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:$command}}' --arg command \
  "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  "$hook_dir/pre-call_1" >/dev/null || fail 'pre hook received the wrong request'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:$command},tool_response:{stdout:"pre denied",stderr:"pre denied",exit_code:126}}' \
  --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  "$hook_dir/post-call_1" >/dev/null || fail 'post hook did not receive the denial outcome'
assert_equal call_2 "$(<$hook_dir/later)" 'deny reached the later hook'
assert_equal ran "$(<$tool_marker)" 'pre-tool denial did not preserve the sibling call'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("state_update","hook_result","tool_result")) |
    if .type == "state_update" then [.type,.name]
    elif .type == "hook_result" then [.type,.lifecycle]
    else [.type,.id,.exit_code] end] == [
      ["state_update","pre/call_1"],
      ["hook_result","pre_tool_use"],
      ["tool_result","call_1",126],
      ["state_update","post/call_1"],
      ["hook_result","post_tool_use"],
      ["tool_result","call_2",0],
      ["state_update","post/call_2"],
      ["hook_result","post_tool_use"]
    ] and
  ($events | map(select(.type == "hook_result"))[0] |
    .model_text == "<context script=\"pre\">\npre context\n</context>" and .user_text == "pre display") and
  ($events | map(select(.type == "tool_result"))[0].model_text | contains("pre denied")) and
  ([$events[] | select((.type == "_draft" and .name == "shell") or
      (.type == "hook_result" and .lifecycle == "post_tool_use")) |
    if .type == "hook_result" then "post" else "running" end] ==
    ["post","running","post"]) and
  ($events | map(select(.type == "_draft" and .name == "shell"))[0].user_text ==
    "**Shell** " + $command + "\n") and
  ($events | map(select(.type == "tool_result"))[1] |
    .user_text == "**Shell** " + $command + "\noutput\nexit 0" and
    .model_text == "output\nexit 0")
' --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  <"$stream" >/dev/null || fail 'tool lifecycle ordering or rendering was wrong'
assert_canonical_session "$session"

# Permission hooks receive supported bypass requests and may allow or deny.
typeset permission="$tmp/permission" permission_input="$tmp/permission-input"
sf_test_hook "$permission" '{"user_text":"${output.stderr}"}' <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 2 && $1 == shell && $2 == call_1 ]] || exit 2
input=$(cat)
print -rn -- "$input" >"$PERMISSION_INPUT"
print -rn -u3 -- '{"state_update":[{"name":"permission/state","value":true}],"action":"allow"}'
print -rn -- 'review context'
print -rn -u2 -- 'review display'
ZSH
export PERMISSION_INPUT=$permission_input
SF_TEST_PROFILE=$(jq -c '.hooks=[] | .sandbox.enabled=true' <<<"$SF_TEST_PROFILE")
sf_test_bind_hooks permission_request "$permission"
session="$tmp/permission-allow.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_BYPASS=true \
  SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- approved' \
  SF_TEST_PROVIDER_REQUEST="$tmp/bypass-request.json" \
  sf_test_run permission "$session" >"$stream" || fail 'permission hook allow failed'
jq -e '.tools[] | select(.name == "shell").input_schema |
  .properties.request_sandbox_access.type == "object" and
  .properties.request_sandbox_access.properties.unrestricted.type == "boolean" and
  (.required | index("request_sandbox_access") == null)' \
  "$tmp/bypass-request.json" >/dev/null || fail 'model schema lacks the access field'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:"print -rn -- approved"},
  sandbox_access:{unrestricted:true,reason:"Required by the test fixture"}}' \
  "$permission_input" >/dev/null || fail 'permission hook received the wrong request'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  [$events[] | select(.type | IN("state_update","hook_result","tool_result")) | .type] ==
    ["state_update","hook_result","tool_result"] and
  ($events | map(select(.type == "hook_result"))[0] |
    .lifecycle == "permission_request" and
    .model_text == "<context script=\"permission\">\nreview context\n</context>" and .user_text == "review display") and
  ([$events[] | select(.type | IN("hook_result","_draft")) | [.type, .sandbox_access]] ==
    [["_draft","requested"],["hook_result",null],["_draft","approved"]]) and
  ($events | map(select(.type == "_draft"))[1].user_text == "**Shell** print -rn -- approved\n") and
  ($events | map(select(.type == "tool_result"))[0] |
    .exit_code == 0 and .sandbox_access == "approved" and
    .user_text == "**Shell** print -rn -- approved\napproved\nexit 0")
' <"$stream" >/dev/null || fail 'permission allow produced the wrong records'

# The core handles ineligible requests without consulting permission hooks.
typeset permission_profile=$SF_TEST_PROFILE gate reason flag
integer gate_status
for gate in sandbox-disabled unsupported no-reason reason-only blank-unrequested; do
  SF_TEST_PROFILE=$permission_profile
  sf_test_shell_tool '.environment=["TMPPREFIX"]'
  reason='Required by the test fixture' flag=true
  case $gate in
    sandbox-disabled) SF_TEST_PROFILE=$(jq -c '.sandbox.enabled=false' <<<"$SF_TEST_PROFILE") ;;
    unsupported) sf_test_shell_tool '.allow_sandbox_bypass=false' ;;
    no-reason) reason='' ;;
    reason-only) flag=false ;;
    blank-unrequested) flag=false reason=' ' ;;
  esac
  rm -f "$permission_input"
  session="$tmp/permission-$gate.jsonl"
  sf_test_session "$session"
  gate_status=0
  SF_TEST_PROVIDER_TOOL_CALL=1 \
    SF_TEST_PROVIDER_TOOL_EXTRA="$(jq -cn --arg reason "$reason" --argjson flag "$flag" '{request_sandbox_access:{unrestricted:$flag,reason:$reason}}')" \
    SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- unreviewed' \
    sf_test_run permission "$session" >"$stream" 2>"$tmp/gate.err" || gate_status=$?
  [[ ! -e $permission_input ]] || fail "permission hook ran for $gate"
  jq -eRn 'all(inputs | fromjson; .type != "_tool_permission_request" and
    (has("sandbox_access") | not) and
    (.type != "hook_result" or .lifecycle != "permission_request"))' <"$stream" >/dev/null ||
    fail "permission was requested for $gate"
  case $gate in
    sandbox-disabled)
      (( gate_status == 0 )) || fail 'disabled sandbox bypass failed the turn'
      jq -e -s 'map(select(.type == "tool_result") | [.exit_code,.model_text]) ==
        [[0,"unreviewed\nexit 0"]]' "$session" >/dev/null ||
        fail 'disabled sandbox did not execute normally' ;;
    unsupported)
      (( gate_status == 0 )) || fail 'unsupported bypass failed the turn'
      jq -e -s 'map(select(.type == "tool_result") | [.exit_code,.model_text]) ==
        [[126,"sandbox bypass is not allowed"]]' "$session" >/dev/null ||
        fail 'unsupported bypass lost the core refusal' ;;
    no-reason)
      (( gate_status == 0 )) || fail 'bypass without a reason failed the turn'
      jq -e -s 'map(select(.type == "tool_result") | [.exit_code,.model_text]) ==
        [[126,"request_sandbox_access requires a reason"]]' "$session" >/dev/null ||
        fail 'missing bypass reason was not refused' ;;
    reason-only)
      (( gate_status == 0 )) || fail 'bypass reason without a request failed the turn'
      jq -e -s 'map(select(.type == "tool_result") | [.exit_code,.model_text]) ==
        [[0,"unreviewed\nexit 0"]]' \
        "$session" >/dev/null || fail 'bypass reason without a request was not refused' \
          "$(jq -c 'select(.type == "tool_result")' "$session")" ;;
    blank-unrequested)
      (( gate_status == 0 )) || fail 'unrequested bypass with a blank reason failed the turn'
      jq -e -s 'map(select(.type == "tool_result") | [.exit_code,.model_text]) ==
        [[0,"unreviewed\nexit 0"]]' "$session" >/dev/null ||
        fail 'unrequested bypass with a blank reason did not execute normally' ;;
  esac
  assert_canonical_session "$session"
done
SF_TEST_PROFILE=$permission_profile
sf_test_shell_tool '.environment=["TMPPREFIX"]'

sf_test_hook "$permission" '{"on":"permission_request"}' <<'ZSH'
#!/usr/bin/env zsh
cat >"$PERMISSION_INPUT"
print -rn -u3 -- '{"action":"deny","reason":"review denied"}'
ZSH
session="$tmp/permission-deny.jsonl"
sf_test_session "$session"
rm -f "$tool_marker"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_BYPASS=true \
  SF_TEST_PROVIDER_TOOL_COMMAND="print -r -- ran >${(q)tool_marker}" \
  sf_test_run permission "$session" >"$stream" || fail 'permission hook deny failed'
[[ ! -e $tool_marker ]] || fail 'denied unrestricted access executed the tool'
jq -eRn --arg command "print -r -- ran >${(q)tool_marker}" '
  [inputs | fromjson] as $events |
  ([$events[] | select(.type == "_draft") | .sandbox_access] == ["requested"]) and
  ($events | map(select(.type == "hook_result"))[0] ==
    {type:"hook_result",section:2,lifecycle:"permission_request",id:"1",action:"deny",reason:"review denied"}) and
  ($events | map(select(.type == "tool_result"))[0] |
    .exit_code == 126 and .sandbox_access == "denied" and
    .model_text == "<sandbox_notice>\nSandbox access denied. The tool was not run.\nReason: review denied\n</sandbox_notice>" and
    .user_text == "**Shell** " + $command + "\n" + .model_text)
' <"$stream" >/dev/null || fail 'permission denial did not settle the call'

# The client may answer before the review hooks finish.
typeset defer_one="$tmp/defer-one" defer_two="$tmp/defer-two"
sf_test_hook "$defer_one" '{"user_text":"reviewed"}' <<'ZSH'
#!/usr/bin/env zsh
cat >"$PERMISSION_INPUT"
ZSH
sf_test_hook "$defer_two" <<'ZSH'
#!/usr/bin/env zsh
[[ -s $PERMISSION_INPUT ]] || exit 2
cat >/dev/null
ZSH
SF_TEST_PROFILE=$(jq -c '.hooks=[]' <<<"$SF_TEST_PROFILE")
sf_test_bind_hooks permission_request "$defer_one" "$defer_two"
session="$tmp/permission-client.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_BYPASS=true \
  SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- approved' \
  sf_test_run permission "$session" \
    '{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}' \
    >"$stream" || fail 'client permission approval failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  ($events | map(select(.type == "_tool_permission_request"))[0] |
    .timeout == 120 and .tool.input.command == "print -rn -- approved") and
  ($events | map(select(.type == "tool_result"))[0] |
    .exit_code == 0 and .sandbox_access == "approved")
' <"$stream" >/dev/null || fail 'client permission was not requested explicitly'
jq -e -s 'all(.[]; .type != "_tool_permission_request" and
  .type != "_tool_permission_response")' "$session" >/dev/null ||
  fail 'permission exchange became durable'

# A client cannot approve unrestricted access for the session.
session="$tmp/permission-unrestricted-session.jsonl"
sf_test_session "$session"
rm -f "$tool_marker"
if SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_BYPASS=true \
    SF_TEST_PROVIDER_TOOL_COMMAND="print -r -- ran >${(q)tool_marker}" \
    sf_test_run permission "$session" \
      '{"type":"_tool_permission_response","id":"permission_1","decision":"approve_session"}' \
      >"$stream" 2>"$tmp/invalid-approval.err"; then
  fail 'unrestricted session approval was accepted'
fi
[[ ! -e $tool_marker ]] || fail 'unrestricted session approval executed the tool'
grep -q 'invalid permission response' "$tmp/invalid-approval.err" ||
  fail 'unrestricted session approval did not fail closed'
head -1 "$session" | jq -e '.profile.sandbox.tools == {}' >/dev/null ||
  fail 'unrestricted session approval changed the session grants'

# Without an answer, the client request is denied and the turn continues.
session="$tmp/permission-no-client.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_BYPASS=true \
  sf_test_run permission "$session" >"$stream" || fail 'closed client failed the turn'
jq -e -s 'map(select(.type == "tool_result"))[0] |
  .exit_code == 126 and (.model_text | endswith("Reason: no client to approve sandbox access\n</sandbox_notice>")) and
  .sandbox_access == "denied"' \
  "$session" >/dev/null || fail 'closed client did not deny the request'

session="$tmp/permission-timeout.jsonl"
SF_TEST_PROFILE=$(jq -c '.sandbox.user_approval_timeout=1' <<<"$SF_TEST_PROFILE") \
  sf_test_session "$session"
# Keep the client connected without delaying the test past the turn's exit.
mkfifo "$tmp/permission-client"
exec {client}<>"$tmp/permission-client"
jq -cn '{type:"user",content:[{type:"text",text:"permission"}]}' >&$client
print -r -- '{"type":"_tool_permission_response","id":"permission_0","decision":"approve_session"}' >&$client
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_BYPASS=true \
  "$ROOT/bin/shellfish" run --jsonl --session "$session" <&$client >"$stream" ||
  fail 'permission timeout failed the turn'
exec {client}>&-
jq -e -s 'map(select(.type == "_tool_permission_request"))[0].timeout == 1' \
  "$stream" >/dev/null || fail 'permission request omitted the configured timeout'
jq -e -s 'map(select(.type == "tool_result"))[0] |
  .exit_code == 126 and (.model_text | endswith("Reason: sandbox access approval timed out\n</sandbox_notice>")) and
  .sandbox_access == "denied"' \
  "$session" >/dev/null || fail 'stale answer or timeout did not deny the request'

# A failing pre hook settles every pending call before the error.
typeset pre_fail="$tmp/pre-fail"
sf_test_hook "$pre_fail" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
exit 4
ZSH
typeset pre_profile=$SF_TEST_PROFILE
SF_TEST_PROFILE=$(jq -c '.hooks=[] | .sandbox.enabled=false' <<<"$SF_TEST_PROFILE")
sf_test_bind_hooks pre_tool_use "$pre_fail"
session="$tmp/pre-failure.jsonl"
sf_test_session "$session"
integer pre_status=0
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COUNT=2 \
  sf_test_run pre "$session" >"$stream" 2>/dev/null || pre_status=$?
(( pre_status == 1 )) || fail 'failing pre hook did not fail the turn'
jq -eRn '
  [inputs | fromjson | select(.type | IN("tool_result","error"))] as $events |
  ($events | map(select(.type == "tool_result") | [.id,.exit_code,.model_text])) == [
    ["call_1",126,"tool call cancelled"],
    ["call_2",126,"tool call cancelled"]] and
  ($events[-1] | .type == "error" and (.user_text | contains("pre_tool_use")))
' <"$stream" >/dev/null || fail 'turn failure did not settle pending calls before its error'
assert_canonical_session "$session"
SF_TEST_PROFILE=$pre_profile

# A failing post hook keeps the settled outcome and its accepted state before the error.
typeset post_fail="$tmp/post-fail"
sf_test_hook "$post_fail" '{"user_text":"must not settle"}' <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -u3 -- '{"state_update":[{"name":"post/failure","value":true}]}'
exit 3
ZSH
SF_TEST_PROFILE=$(jq -c '.hooks=[] | .sandbox.enabled=false' <<<"$SF_TEST_PROFILE")
sf_test_bind_hooks post_tool_use "$post_fail"
session="$tmp/post-failure.jsonl"
sf_test_session "$session"
integer post_status=0
SF_TEST_PROVIDER_TOOL_CALL=1 sf_test_run post "$session" >"$stream" || post_status=$?
(( post_status == 1 )) || fail 'failing post hook did not fail the turn'
jq -eRn '
  [inputs | fromjson | select(.type | IN("state_update","hook_result","tool_result","error"))] as $events |
  ($events | any(.type == "hook_result") | not) and
  ($events[-3] | .type == "tool_result" and .id == "call_1" and .exit_code == 0) and
  ($events[-2] | .type == "state_update" and .name == "post/failure" and .value == true) and
  ($events[-1] | .type == "error" and (.user_text | contains("post_tool_use")))
' <"$stream" >/dev/null || fail 'post failure lost or reordered the known outcome'
assert_canonical_session "$session"
