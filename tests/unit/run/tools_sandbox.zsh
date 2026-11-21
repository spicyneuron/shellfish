#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-tool-sandbox
mkdir "$tmp/host-temp"
export TMPDIR="$tmp/host-temp" TMPPREFIX="$tmp/manifest-prefix"
sf_test_frozen_profile
typeset session stream="$tmp/stream"
SF_TEST_PROFILE=$(jq -c '.sandbox.enabled=true' <<<"$SF_TEST_PROFILE")
typeset env_command='print -rn -- "${DECLARED-unset} ${UNDECLARED-unset} ${EXPORTED-unset} ${SHELLFISH_SHARE_DIR-unset}"'
mkdir -p "$SHELLFISH_DIR"
print -rl -- DECLARED=declared-file UNDECLARED=undeclared-file >"$SHELLFISH_DIR/.env"
export EXPORTED=exported

# A sandboxed tool needs fence on PATH when it runs. ZDOTDIR keeps a user's
# .zshenv from restoring PATH.
SF_TEST_PROFILE=$(jq -c '.hooks=[] | .sandbox.enabled=true' <<<"$SF_TEST_PROFILE")
typeset no_fence="$tmp/no-fence"
mkdir "$no_fence"
ln -s "$commands[jq]" "$commands[zsh]" "$no_fence/"
session="$tmp/sandbox-missing.jsonl"
sf_test_session "$session"
ZDOTDIR=$no_fence PATH="$no_fence:/usr/bin:/bin" SF_TEST_PROVIDER_TOOL_CALL=1 \
  sf_test_run sandbox "$session" >"$stream" 2>/dev/null ||
  fail 'missing sandbox runner failed the turn'
jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 126 and (.user_text | contains("sandboxing requires fence")) and
  (.model_content[0].text | contains("sandboxing requires fence"))
' <"$stream" >/dev/null || fail 'missing sandbox runner was not skipped'

# Bundled helpers are readable outside the project, without exposing other resources.
sf_test_shell_tool '.environment=[]'
SF_TEST_PROFILE=$(jq -c '.hooks=[] | .sandbox.tools={}' <<<"$SF_TEST_PROFILE")
mkdir "$tmp/project"
session="$tmp/sandbox-library.jsonl"
( builtin cd -- "$tmp/project"; sf_test_session "$session" )
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND='
  source "$SHELLFISH_SHARE_DIR/lib/skills.zsh" || exit 1
  sf_skills_scalar ready || exit 1
  [[ ! -r $SHELLFISH_SHARE_DIR/help.txt ]] || exit 2
  if made=$(mktemp "$SHELLFISH_SHARE_DIR/lib/sandbox-write.XXXXXX" 2>/dev/null); then
    rm -f -- "$made"
    exit 3
  fi
  print -rn -- "$REPLY"
' sf_test_run library "$session" >"$stream" || fail 'bundled library turn failed'
jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 0 and .model_content[0].text == "ready\nexit 0"
' <"$stream" >/dev/null || fail 'bundled library access was missing or too broad'
jq --arg library "$SF_SHARE/lib" '.filesystem.denyRead += [$library]' \
  "$tmp/tools/shell/fence.jsonc" >"$tmp/policy.json"
mv "$tmp/policy.json" "$tmp/tools/shell/fence.jsonc"
session="$tmp/sandbox-library-denied.jsonl"
( builtin cd -- "$tmp/project"; sf_test_session "$session" )
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND='
  if cat "$SHELLFISH_SHARE_DIR/lib/capped.zsh" >/dev/null 2>&1; then exit 1; fi
  print -rn -- blocked
' sf_test_run library "$session" >"$stream" || fail 'denied library turn failed'
assert_equal $'blocked\nexit 0' "$(jq -r 'select(.type == "tool_result") | .model_content[0].text' "$stream")" \
  'baseline library access overrode a policy deny'

# The clean environment preserves Fence's proxy and inherited domain denies.
sf_test_shell_tool '.environment=["TMPPREFIX"]'
jq '.network.allowedDomains=["baseline.example.com"] |
  .network.deniedDomains=["blocked.invalid"]' "$tmp/tools/shell/fence.jsonc" >"$tmp/policy.json"
mv "$tmp/policy.json" "$tmp/tools/shell/fence.jsonc"
SF_TEST_PROFILE=$(jq -c '.sandbox.tools.shell={filesystem:{allowRead:[],allowWrite:[]},network:{allowedDomains:["blocked.invalid"]}}' \
  <<<"$SF_TEST_PROFILE")
session="$tmp/sandbox-network.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND="curl --silent --show-error --max-time 3 --output /dev/null --write-out '%{http_code}' http://blocked.invalid" \
  sf_test_run sandbox "$session" >"$stream" || fail 'sandbox network turn failed'
jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 0 and .model_content[0].text == "403\nexit 0"
' <"$stream" >/dev/null || fail 'sandbox proxy was unavailable or a domain deny was lost'
assert_canonical_session "$session"

# A sandbox violation enters the same captured output seen by templates and hooks.
mkdir "$tmp/bin"
ln -s "$commands[fence]" "$tmp/real-fence"
typeset fence="$tmp/bin/fence"
typeset fence_arguments="$tmp/fence-arguments"
cat >"$fence" <<'ZSH'
#!/usr/bin/env zsh
log='' settings=''
base=${0:A:h:h}
[[ ${1-} != config ]] || exit 1
print -rl -- "$@" >"$base/fence-arguments"
while (( $# )); do
  case $1 in
    --fence-log-file) log=$2; shift 2 ;;
    --settings) settings=$2; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
cp "$settings" "$base/fence-policy.json" || exit 1
"$base/real-fence" config show --settings "$settings" >"$base/fence-resolved.json" 2>/dev/null || exit 1
[[ -z $log ]] || print -r -- '[fence:logstream] ✗ file-write-create /etc/denied' >"$log"
exec "$@"
ZSH
chmod +x "$fence"
export PATH="$tmp/bin:$PATH"
typeset sandbox_post="$tmp/sandbox-post" sandbox_output="$tmp/sandbox-output.json"
sf_test_hook "$sandbox_post" <<'ZSH'
#!/usr/bin/env zsh
jq -c .tool_response >"$SANDBOX_OUTPUT"
ZSH
export SANDBOX_OUTPUT=$sandbox_output
sf_test_bind_hooks post_tool_use "$sandbox_post"
SF_TEST_PROFILE=$(jq -c --arg reader "$ROOT/share/tools/read_file" '
  .tools += [$reader] | .sandbox.tools={
    shell:{filesystem:{allowRead:["/shell/read"],allowWrite:["/shell/write"]},network:{allowedDomains:["github.com","*.npmjs.org","blocked.invalid"]}},
    read_file:{filesystem:{allowRead:["/reader/read"],allowWrite:["/reader/write"]},network:{allowedDomains:["reader.example.com"]}}}
' <<<"$SF_TEST_PROFILE")
session="$tmp/sandbox-denied.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- output; exit 3' \
  sf_test_run sandbox "$session" >"$stream" || fail 'sandbox denial turn failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 3 and
  (.user_text | contains("**Shell** print -rn -- output; exit 3\noutput\nexit 3\n<sandbox_notice>")) and
  (.model_content[0].text | contains("output\nexit 3\n<sandbox_notice>"))
' <"$stream" >/dev/null || fail 'sandbox denial did not annotate the model text'
jq -e --slurpfile output "$sandbox_output" '
  . as $result |
  $output[0].exit_code == $result.exit_code and
  $output[0].stdout == $result.model_content[0].text and
  ($output[0].stdout | contains("<sandbox_notice>"))
' < <(jq -c 'select(.type == "tool_result")' "$stream") >/dev/null ||
  fail 'post_tool_use did not receive the rendered sandbox output'
SF_TEST_PROFILE=$(jq -c '.hooks=[]' <<<"$SF_TEST_PROFILE")
jq -e --arg base "$tmp/tools/shell/fence.jsonc" --arg library "$SF_SHARE/lib" '
  .extends == $base and
  .filesystem == {allowRead:["/shell/read",$library],allowWrite:["/shell/write"]} and
  .network.allowedDomains == ["github.com","*.npmjs.org","blocked.invalid"]
' "$tmp/fence-policy.json" >/dev/null || fail 'domain policy did not extend the selected tool'
jq -e '
  .network.allowedDomains == ["baseline.example.com","github.com","*.npmjs.org","blocked.invalid"] and
  .network.deniedDomains == ["blocked.invalid"] and
  .network.allowLocalOutbound == false and
  .filesystem.defaultDenyRead == true and
  (.filesystem.denyWrite | index("**/.shellfish/**") != null)
' "$tmp/fence-resolved.json" >/dev/null || fail 'domain grants replaced baseline sandbox policy'
typeset policy_path
policy_path=$(jq -rRn '[inputs] | .[index("--settings") + 1]' <"$fence_arguments") ||
  fail 'cannot read temporary sandbox policy path'
[[ ! -e $policy_path ]] || fail 'temporary sandbox policy survived tool cleanup'

# Path grants need policy permissions even without any domain grants.
SF_TEST_PROFILE=$(jq -c '.sandbox.tools.shell.network.allowedDomains=[]' <<<"$SF_TEST_PROFILE")
session="$tmp/sandbox-path-grants.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 sf_test_run paths "$session" >"$stream" ||
  fail 'path-only sandbox grants failed the turn'
jq -e --arg library "$SF_SHARE/lib" '
  .filesystem == {allowRead:["/shell/read",$library],allowWrite:["/shell/write"]} and
  .network.allowedDomains == []' "$tmp/fence-policy.json" >/dev/null ||
  fail 'path-only grants did not reach the sandbox policy'

SF_TEST_PROFILE=$(jq -c '.tools |= map(select(endswith("/read_file") | not)) |
  .sandbox.tools={}' <<<"$SF_TEST_PROFILE")
jq -eRn --arg temp "${TMPDIR:A}" '
  [inputs] as $args |
  [range(0; $args | length) as $i |
    select($args[$i] == "--expose-host-path-rw") | $args[$i + 1]] as $paths |
  ($paths | index("/tmp") != null and index($temp) != null)
' <"$fence_arguments" >/dev/null || fail 'sandbox did not grant the standard temp directories'
if [[ $OSTYPE == darwin* ]]; then
  typeset darwin_temp
  darwin_temp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
  jq -eRn --arg temp "${darwin_temp:A}" '
    [inputs] as $args |
    [range(0; $args | length) as $i |
      select($args[$i] == "--expose-host-path-rw") | $args[$i + 1]] |
    index($temp) != null
  ' <"$fence_arguments" >/dev/null || fail 'sandbox did not grant the Darwin temp directory'
fi
assert_canonical_session "$session"

session="$tmp/sandbox-tolerated.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- output' \
  sf_test_run sandbox "$session" >"$stream" || fail 'tolerated denial turn failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 0 and .model_content[0].text == "output\nexit 0"
' <"$stream" >/dev/null || fail 'a succeeding tool was annotated'
jq -e --arg library "$SF_SHARE/lib" '
  has("extends") and .filesystem == {allowRead:[$library]} and (has("network") | not)
' "$tmp/fence-policy.json" >/dev/null || fail 'baseline library access needed profile grants'

# Replacement skips the bundled policy, including its denies and network list.
typeset native_profile=$SF_TEST_PROFILE policy_fixture="$tmp/policy-fixture"
mkdir "$policy_fixture"
for replacement in false true; do
  SF_TEST_PROFILE=$(jq -c --arg dir "$policy_fixture" --argjson replace "$replacement" '
    .sandbox.tools.shell={replace:$replace, filesystem:{defaultDenyRead:true,
      allowRead:[$dir],denyRead:[$dir + "/*.key"]},command:{useDefaults:false}}
  ' <<<"$native_profile")
  session="$tmp/policy-$replacement.jsonl"
  sf_test_session "$session"
  SF_TEST_PROVIDER_TOOL_CALL=1 sf_test_run policy "$session" >"$stream" ||
    fail 'custom policy turn failed'
  jq -e --argjson replace "$replacement" --arg dir "$policy_fixture" --arg library "$SF_SHARE/lib" '
    (has("replace") | not) and .command.useDefaults == false and
    (.filesystem.allowRead | index($library) != null) and
    (.filesystem.denyRead | index($dir + "/*.key") != null) and
    ((.filesystem.denyRead | index("**/.env") == null) == $replace) and
    ((.network.allowedDomains // [] | index("baseline.example.com") == null) == $replace)
  ' "$tmp/fence-resolved.json" >/dev/null || fail 'policy replacement or native merge changed'
done
typeset parent_policy="$tmp/parent-policy.json"
jq -n --arg dir "$policy_fixture" '{filesystem:{allowRead:[$dir]},
  network:{allowedDomains:["parent.example.com"]}}' >"$parent_policy"
SF_TEST_PROFILE=$(jq -c --arg parent "$parent_policy" '
  .sandbox.tools.shell={replace:true,extends:$parent,
    filesystem:{allowRead:["/custom/read-*"],allowExecute:["/custom/bin"]},
    network:{allowedDomains:["child.example.com"]}}
' <<<"$native_profile")
session="$tmp/inherited.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 sf_test_run inherited "$session" >"$stream" ||
  fail 'inherited policy turn failed'
jq -e --arg dir "$policy_fixture" --arg library "$SF_SHARE/lib" '
  (.filesystem.allowRead | index($dir) != null) and
  (.filesystem.allowRead | index($library) != null) and
  .filesystem.allowExecute == ["/custom/bin"] and
  (.network.allowedDomains | index("parent.example.com") != null and
    index("child.example.com") != null) and
  (.network.allowedDomains | index("baseline.example.com") == null)
' "$tmp/fence-resolved.json" >/dev/null || fail 'native extends lost a policy layer'
if grep -Fxq "$policy_fixture" "$fence_arguments" || grep -Fxq '/custom/read-*' "$fence_arguments" ||
    grep -Fxq "$SF_SHARE/lib" "$fence_arguments"; then
  fail 'native policy paths received duplicate host-path mounts'
fi
SF_TEST_PROFILE=$native_profile

# An approved grant request runs the call sandboxed with the extra access.
typeset granted="$tmp/granted" grant_input
mkdir "$granted"
grant_input=$(jq -cn --arg dir "$granted" '{request_sandbox_access:{
  write:[$dir],domains:["Grant.Example.com"],reason:"Write the fixture output"}}')
session="$tmp/grant-once.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
  SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- granted' \
  SF_TEST_PROVIDER_REQUEST="$tmp/grant-request.json" \
  sf_test_run grant "$session" \
    '{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}' \
    >"$stream" || fail 'grant approval turn failed'
jq -e '.tools[] | select(.name == "shell").input_schema.properties.request_sandbox_access |
  .type == "object" and (.required // []) == []' "$tmp/grant-request.json" >/dev/null ||
  fail 'model schema lacks the grant field'
jq -eRn --arg dir "$granted" '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request"))[0].access ==
    {read:[],write:[$dir],domains:["grant.example.com"]}) and
  ([$events[] | select(.type == "_draft") | .sandbox_access] == ["requested","approved"]) and
  ($events | map(select(.type == "tool_result"))[0] |
    .exit_code == 0 and .model_content[0].text == "granted\nexit 0" and .sandbox_access == "approved") and
  ($events | any(.type == "_session_update") | not)
' <"$stream" >/dev/null || fail 'grant approval produced the wrong records'
# Approved access belongs in the policy, not in overriding host-path mounts.
jq -e --arg dir "$granted" --arg library "$SF_SHARE/lib" '
  .network.allowedDomains == ["grant.example.com"] and
  .filesystem == {allowRead:[$library],allowWrite:[$dir]}' "$tmp/fence-policy.json" >/dev/null ||
  fail 'grant did not reach the sandbox policy'
head -1 "$session" | jq -e '.profile.sandbox.tools == {}' >/dev/null ||
  fail 'a one-call grant changed the session profile'
assert_canonical_session "$session"

# A session approval keeps the grant, so later calls have it without asking.
SF_TEST_PROFILE=$(jq -c '.sandbox.tools.shell={replace:true,
  filesystem:{denyWrite:["**/protected"]}}' <<<"$SF_TEST_PROFILE")
session="$tmp/grant-session.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
  SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- kept' \
  sf_test_run grant "$session" \
    '{"type":"_tool_permission_response","id":"permission_1","decision":"approve_session"}' \
    >"$stream" || fail 'session grant turn failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_session_update")) and
  ($events | map(select(.type == "tool_result"))[0] |
    .exit_code == 0 and .sandbox_access == "session" and
    (.model_content[0].text | startswith("kept\nexit 0\n<sandbox_notice>This access is granted")))
' <"$stream" >/dev/null || fail 'session grant produced the wrong records'
head -1 "$session" | jq -e --arg dir "$granted" '.profile.sandbox.tools.shell ==
  {replace:true,filesystem:{denyWrite:["**/protected"],allowRead:[],allowWrite:[$dir]},
    network:{allowedDomains:["grant.example.com"]}}' >/dev/null ||
  fail 'session grant did not join the session profile'
: >"$fence_arguments"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- again' \
  sf_test_run again "$session" >"$stream" || fail 'turn after a session grant failed'
jq -eRn '[inputs | fromjson] | all(.type != "_tool_permission_request")' <"$stream" >/dev/null ||
  fail 'a kept grant asked again'
jq -e --arg dir "$granted" '.filesystem.allowWrite == [$dir]' \
  "$tmp/fence-resolved.json" >/dev/null || fail 'a kept grant did not reach a later call'
assert_canonical_session "$session"

# Explicit requests for kept access run without another review, including
# reads beneath a write grant and equivalent path spellings.
grant_input=$(jq -cn --arg dir "$granted" '{request_sandbox_access:{
  read:[$dir + "/child"],write:[$dir + "/./"],domains:["Grant.Example.com"],
  reason:"Reuse the approved access"}}')
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
  SF_TEST_PROVIDER_REQUEST="$tmp/kept-request.json" \
  SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- already' \
  sf_test_run again "$session" >"$stream" || fail 'repeated access request failed'
jq -eRn '[inputs | fromjson] as $events |
  ($events | all(.type != "_tool_permission_request" and .type != "_session_update")) and
  ($events | map(select(.type == "tool_result"))[0] |
    .exit_code == 0 and .sandbox_access == "session" and
    (.model_content[0].text | contains("This access is granted for the rest of this session")))
' <"$stream" >/dev/null || fail 'kept access was requested again'
jq -e '.messages | any(.type == "tool_result" and
  (.content[0].text | contains("This access is granted for the rest of this session")))' \
  "$tmp/kept-request.json" >/dev/null || fail 'the model did not receive the session access notice'

# Review hooks receive the resolved access still needed and the operation alone.
typeset permission="$tmp/permission" permission_input="$tmp/permission-input"
sf_test_hook "$permission" '{"on":"permission_request"}' <<'ZSH'
#!/usr/bin/env zsh
cat >"$PERMISSION_INPUT"
print -r -u3 -- '{"action":"deny","reason":"review denied"}'
ZSH
export PERMISSION_INPUT=$permission_input
typeset review_session="$tmp/grant-review.jsonl"
SF_TEST_PROFILE=$(jq -c --arg dir "$granted" --arg hook "$permission" '
  .hooks=[$hook] | .sandbox.tools.shell={filesystem:{allowRead:[],allowWrite:[$dir]},network:{allowedDomains:[]}}
' <<<"$SF_TEST_PROFILE") sf_test_session "$review_session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$(jq -cn --arg dir "$granted" \
  '{request_sandbox_access:{read:["notes",$dir],reason:"Read the notes"}}') \
  sf_test_run review "$review_session" >"$stream" || fail 'reviewed access turn failed'
jq -e --arg notes "$(pwd -P)/notes" '
  .tool_input == {command:"true"} and
  .sandbox_access == {read:[$notes],write:[],domains:[],reason:"Read the notes"}
' "$permission_input" >/dev/null || fail 'review hook received unresolved access'

# A partially covered request asks only for new access, not path-prefix lookalikes.
grant_input=$(jq -cn --arg dir "$granted" '{request_sandbox_access:{
  read:[$dir + "/child"],write:[$dir,$dir + "-other"],
  domains:["grant.example.com","new.example.com"],reason:"Need more access"}}')
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
  sf_test_run more "$session" \
    '{"type":"_tool_permission_response","id":"permission_1","decision":"deny"}' \
    >"$stream" || fail 'partially covered access failed the turn'
jq -eRn --arg dir "$granted" '[inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | map(.access)) ==
    [{read:[],write:[$dir + "-other"],domains:["new.example.com"]}] and
  ($events | map(select(.type == "tool_result"))[0].exit_code == 126)
' <"$stream" >/dev/null || fail 'partial request did not isolate missing access'

# Read grants cover children, and domain wildcards cover subdomains, not the apex.
typeset grant_profile=$SF_TEST_PROFILE
SF_TEST_PROFILE=$(jq -c --arg dir "$granted" '.sandbox.tools.shell =
  {filesystem:{allowRead:[$dir],allowWrite:[]},network:{allowedDomains:["*.grant.example.com"]}}' <<<"$SF_TEST_PROFILE")
session="$tmp/grant-covered.jsonl"
sf_test_session "$session"
grant_input=$(jq -cn --arg dir "$granted" '{request_sandbox_access:{
  read:[$dir + "/child"],domains:["api.grant.example.com","*.child.grant.example.com"],
  reason:"Already allowed"}}')
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
  sf_test_run covered "$session" >"$stream" || fail 'covered read and domains failed'
jq -eRn '[inputs | fromjson] as $events |
  ($events | all(.type != "_tool_permission_request")) and
  ($events | map(select(.type == "tool_result"))[0] |
    .exit_code == 0 and .sandbox_access == "session")
' <"$stream" >/dev/null || fail 'covered read or domain asked for approval'
grant_input=$(jq -cn --arg dir "$granted" '{request_sandbox_access:{
  read:[$dir],write:[$dir],domains:["grant.example.com","evilgrant.example.com"],
  reason:"Need writes and the apex"}}')
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
  sf_test_run uncovered "$session" \
    '{"type":"_tool_permission_response","id":"permission_1","decision":"deny"}' \
    >"$stream" || fail 'read escalation failed the turn'
jq -eRn --arg dir "$granted" '[inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | map(.access)) ==
    [{read:[],write:[$dir],domains:["grant.example.com","evilgrant.example.com"]}] and
  ($events | map(select(.type == "tool_result"))[0].exit_code == 126)
' <"$stream" >/dev/null || fail 'read grant or wildcard silently escalated access'
SF_TEST_PROFILE=$grant_profile

# Native relative paths and an unrestricted domain allowlist cover requests.
SF_TEST_PROFILE=$(jq -c '.sandbox.tools.shell={filesystem:{allowRead:["."],allowWrite:["."]},
  network:{allowedDomains:["*"]}}' <<<"$SF_TEST_PROFILE")
session="$tmp/native-covered.jsonl"
sf_test_session "$session"
grant_input=$(jq -cn --arg cwd "$PWD" '{request_sandbox_access:{
  read:[$cwd + "/child"],write:[$cwd + "/child"],domains:["any.example.com"],
  reason:"Already allowed by the native policy"}}')
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
  sf_test_run covered "$session" >"$stream" || fail 'native coverage failed the turn'
jq -eRn '[inputs | fromjson] as $events |
  ($events | all(.type != "_tool_permission_request")) and
  ($events | map(select(.type == "tool_result"))[0].sandbox_access == "session")
' <"$stream" >/dev/null || fail 'native paths or the domain allowlist asked for approval'
SF_TEST_PROFILE=$grant_profile

# The core refuses malformed grant requests without asking.
for grant_input in '{"request_sandbox_access":true}' \
    '{"request_sandbox_access":"yes"}' \
    '{"request_sandbox_access":{"read":"/x","reason":"bad type"}}' \
    '{"request_sandbox_access":{"unrestricted":"true","reason":"bad type"}}' \
    '{"request_sandbox_access":{"read":["/x"]}}' \
    '{"request_sandbox_access":{"domains":["a b"],"reason":"bad host"}}' \
    '{"request_sandbox_access":{"read":["/x"],"unrestricted":true,"reason":"both"}}'; do
  session="$tmp/grant-invalid.jsonl"
  sf_test_session "$session"
  SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_EXTRA=$grant_input \
    sf_test_run grant "$session" >"$stream" || fail 'invalid grant failed the turn'
  jq -eRn '[inputs | fromjson] as $events |
    ($events | any(.type == "_tool_permission_request") | not) and
    ($events | map(select(.type == "tool_result"))[0] |
      .exit_code == 126 and (.model_content[0].text | startswith("request_sandbox_access")) and
      (has("sandbox_access") | not))
  ' <"$stream" >/dev/null || fail "invalid grant was not refused: $grant_input"
done

# Empty access values run normally without requesting permission.
for grant_input in '{}' 'null' 'false' '""' \
    '{"read":[],"write":[],"domains":[],"unrestricted":false,"reason":"not needed"}' \
    '{"reason":"not needed"}'; do
  session="$tmp/access-empty.jsonl"
  sf_test_session "$session"
  SF_TEST_PROVIDER_TOOL_CALL=1 \
    SF_TEST_PROVIDER_TOOL_EXTRA="{\"request_sandbox_access\":$grant_input}" \
    SF_TEST_PROVIDER_TOOL_COMMAND='print -rn -- ordinary' \
    sf_test_run empty "$session" >"$stream" || fail 'empty access request failed the turn'
  jq -eRn '[inputs | fromjson] as $events |
    ($events | all(.type != "_tool_permission_request")) and
    ($events | map(select(.type == "tool_result"))[0] |
      .exit_code == 0 and (has("sandbox_access") | not) and
      .model_content[0].text == "ordinary\nexit 0")
  ' <"$stream" >/dev/null || fail "empty access requested permission: $grant_input"
done

# A sandboxed tool starts clean apart from its declared names.
sf_test_shell_tool '.environment=["DECLARED"]'
session="$tmp/sandbox-env.jsonl"
sf_test_session "$session"
SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND=$env_command \
  sf_test_run sandbox "$session" >"$stream" || fail 'sandboxed environment turn failed'
jq -eRn --arg share "$SF_SHARE" '[inputs | fromjson | select(.type == "tool_result")][0].model_content[0].text ==
  ("declared-file unset unset " + $share + "\nexit 0")' <"$stream" >/dev/null ||
  fail 'sandboxed tool saw values beyond its declared names'
for manifest in '.environment=[]' 'del(.environment)'; do
  sf_test_shell_tool "$manifest"
  sf_test_session "$session"
  SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND=$env_command \
    sf_test_run sandbox "$session" >"$stream" || fail 'empty sandbox environment turn failed'
  jq -eRn --arg share "$SF_SHARE" '[inputs | fromjson | select(.type == "tool_result")][0].model_content[0].text ==
    ("unset unset unset " + $share + "\nexit 0")' <"$stream" >/dev/null ||
    fail 'a sandboxed tool without declarations received .env credentials'
done
