#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-tool-contract
mkdir "$tmp/host-temp"
export TMPDIR="$tmp/host-temp" TMPPREFIX="$tmp/manifest-prefix"
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0
sf_test_runtime

# The bundled shell decodes multiline commands once and preserves exit status.
typeset shell_tool="$ROOT/share/profiles/default/tools/shell/run"
assert_equal $'first\nsecond' "$(print -rn -- \
  '{"command":"print -r -- first; print -r -- second"}' | "$shell_tool")"
integer shell_status=0
print -rn -- '{"command":"exit 7"}' | "$shell_tool" >/dev/null || shell_status=$?
(( shell_status == 7 )) || fail 'shell tool changed the command exit status'
if print -rn -- '{"command":"true","extra":true}' | "$shell_tool" >/dev/null 2>&1; then
  fail 'shell tool accepted an unknown input field'
fi

# Tool rendering uses the shared component vocabulary.
SF_TEST_RUNTIME=$(jq -c '
  .harness.tools[0].manifest.environment=["TMPPREFIX"] |
  .harness.tools[0].manifest.render={
    initial_user_text:"${name}\n${input.command}",
    user_text:"${name}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
    model_text:"${output.stdout}${output.stderr}\nexit ${output.exit_code}",
    permission_user_text:"${input.command}"
  }
' <<<"$SF_TEST_RUNTIME")

# Tools use the host temp directory rather than a Shellfish-owned turn directory.
typeset temp_session="$tmp/tool-temp.jsonl" temp_stream="$tmp/tool-temp.stream"
sf_test_session "$temp_session"
SF_TEST_BACKEND_TOOL_CALL=1 \
  SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- "$TMPDIR|$TMPPREFIX"' \
  sf_test_run temp "$temp_session" >"$temp_stream" || fail 'tool temp environment turn failed'
jq -eRn --arg expected "${TMPDIR:A}|${TMPDIR:A}/zsh" '
  [inputs | fromjson | select(.type == "tool_result")][0].model_text ==
    ($expected + "\nexit 0")
' <"$temp_stream" >/dev/null || fail 'tool did not receive the host temp environment'

# Hooks receive all of .env; tools receive only the .env names they declare.
typeset env_config="$XDG_CONFIG_HOME/shellfish" env_hook="$tmp/env-hook" env_seen="$tmp/env-seen"
typeset env_session="$tmp/env.jsonl" env_stream="$tmp/env.stream" base_runtime=$SF_TEST_RUNTIME
typeset env_command='print -rn -- "${DECLARED-unset} ${UNDECLARED-unset} ${EXPORTED-unset}"'
mkdir -p "$env_config"
print -rl -- DECLARED=declared-file UNDECLARED=undeclared-file >"$env_config/.env"
cat >"$env_hook" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- "${UNDECLARED-unset}" >"$ENV_SEEN"
ZSH
chmod +x "$env_hook"
export ENV_SEEN=$env_seen EXPORTED=exported
SF_TEST_RUNTIME=$(jq -c --arg hook "$env_hook" '
  .harness.tools[0].manifest.environment=["DECLARED"] |
  .harness.post_tool_use=[{command:$hook,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
sf_test_session "$env_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=$env_command \
  sf_test_run env "$env_session" >"$env_stream" || fail 'tool environment turn failed'
jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0].model_text ==
  "declared-file unset exported\nexit 0"' <"$env_stream" >/dev/null ||
  fail 'unsandboxed tool did not receive exactly its declared .env names'
assert_equal undeclared-file "$(<$env_seen)" 'hook did not receive an undeclared .env key'
SF_TEST_RUNTIME=$base_runtime

# Tool temp cannot redirect the next call's core-owned input write.
typeset input_target="$tmp/tool-input-target" input_session="$tmp/tool-input.jsonl"
typeset input_stream="$tmp/tool-input.stream"
sf_test_session "$input_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  SF_TEST_BACKEND_TOOL_COMMAND="ln -sf ${(q)input_target} \"\$TMPDIR/input\"" \
  sf_test_run input "$input_session" >"$input_stream" || fail 'tool input isolation turn failed'
[[ ! -e $input_target ]] || fail 'tool temp redirected a later input write'

# Pre-tool denial is sticky, preserves sibling calls, and still reaches post hooks.
typeset pre="$tmp/pre" later="$tmp/pre-later" post="$tmp/post"
typeset hook_dir="$tmp/hook-inputs" tool_marker="$tmp/tool-ran"
mkdir "$hook_dir"
cat >"$pre" <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$HOOK_DIR/pre-$id"
print -rn -u3 -- "{\"state\":[{\"name\":\"pre/$id\",\"value\":true}]}"
if [[ $id == call_1 ]]; then
  print -rn -- 'pre context'
  print -rn -u2 -- 'pre display'
  exit 10
fi
ZSH
cat >"$later" <<'ZSH'
#!/usr/bin/env zsh
id=$(jq -r '.tool_use_id')
print -r -- "$id" >>"$HOOK_DIR/later"
ZSH
cat >"$post" <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$HOOK_DIR/post-$id"
print -rn -u3 -- "{\"state\":[{\"name\":\"post/$id\",\"value\":true}]}"
ZSH
chmod +x "$pre" "$later" "$post"
export HOOK_DIR=$hook_dir TOOL_MARKER=$tool_marker
SF_TEST_RUNTIME=$(jq -c --arg pre "$pre" --arg later "$later" --arg post "$post" '
  .harness.pre_tool_use=[
    {command:$pre,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}},
    {command:$later,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}
  ] |
  .harness.post_tool_use=[{command:$post,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
typeset session="$tmp/denied.jsonl" stream="$tmp/denied.stream"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  SF_TEST_BACKEND_TOOL_COMMAND="print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  sf_test_run tools "$session" >"$stream" || fail 'pre-tool denial turn failed'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:$command}}' --arg command \
  "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  "$hook_dir/pre-call_1" >/dev/null || fail 'pre hook received the wrong request'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:$command},tool_response:{stdout:"",stderr:"",exit_code:126}}' \
  --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  "$hook_dir/post-call_1" >/dev/null || fail 'post hook did not receive the denial outcome'
assert_equal $'call_1\ncall_2' "$(<$hook_dir/later)" \
  'status 10 did not continue pre hooks for every call'
assert_equal ran "$(<$tool_marker)" 'pre-tool denial did not preserve the sibling call'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("state","hook_result","tool_result")) |
    if .type == "state" then [.type,.name]
    elif .type == "hook_result" then [.type,.lifecycle,.exit_code]
    else [.type,.id,.exit_code] end] == [
      ["state","pre/call_1"],
      ["hook_result","pre_tool_use",10],
      ["state","post/call_1"],
      ["tool_result","call_1",126],
      ["state","pre/call_2"],
      ["state","post/call_2"],
      ["tool_result","call_2",0]
    ] and
  ($events | map(select(.type == "hook_result"))[0] |
    .model_text == "pre context" and .user_text == "pre display") and
  ($events | map(select(.type == "_tool_activity"))[1].user_text) ==
    "shell\n" + $command and
  ($events | map(select(.type == "tool_result"))[1] |
    .user_text == "shell\noutput\nexit 0" and .model_text == "output\nexit 0")
' --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  <"$stream" >/dev/null || fail 'tool lifecycle ordering or rendering was wrong'
assert_canonical_session "$session"

# Permission hooks receive the request and may halt with allow or deny.
typeset permission="$tmp/permission" permission_input="$tmp/permission-input"
cat >"$permission" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 2 && $1 == shell && $2 == call_1 ]] || exit 2
input=$(cat)
print -rn -- "$input" >"$PERMISSION_INPUT"
print -rn -u3 -- '{"state":[{"name":"permission/state","value":true}],"action":"allow"}'
print -rn -- 'review context'
print -rn -u2 -- 'review display'
exit 11
ZSH
chmod +x "$permission"
export PERMISSION_INPUT=$permission_input
SF_TEST_RUNTIME=$(jq -c --arg hook "$permission" '
  .harness.pre_tool_use=[] | .harness.post_tool_use=[] |
  .harness.sandbox=true |
  .harness.permission_request=[{command:$hook,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
session="$tmp/permission-allow.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- approved' \
  sf_test_run permission "$session" >"$stream" || fail 'permission hook allow failed'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",tool_input:{
  command:"print -rn -- approved",request_sandbox_bypass:true,
  sandbox_bypass_reason:"Required by the test fixture"}}' \
  "$permission_input" >/dev/null || fail 'permission hook received the wrong request'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_tool_permission_request") | not) and
  [$events[] | select(.type | IN("state","hook_result","tool_result")) | .type] ==
    ["state","hook_result","tool_result"] and
  ($events | map(select(.type == "hook_result"))[0] |
    .lifecycle == "permission_request" and .exit_code == 11 and
    .model_text == "review context" and .user_text == "review display") and
  ($events | map(select(.type == "tool_result"))[0].exit_code) == 0
' <"$stream" >/dev/null || fail 'permission allow produced the wrong records'

cat >"$permission" <<'ZSH'
#!/usr/bin/env zsh
cat >"$PERMISSION_INPUT"
print -rn -u3 -- '{"action":"deny","reason":"review denied"}'
exit 11
ZSH
chmod +x "$permission"
session="$tmp/permission-deny.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_run permission "$session" >"$stream" || fail 'permission hook deny failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 126 and (.model_text | contains("review denied"))
' <"$stream" >/dev/null || fail 'permission denial did not settle the call'

# No hook defers to the client; the permission exchange stays transient.
SF_TEST_RUNTIME=$(jq -c '.harness.permission_request=[]' <<<"$SF_TEST_RUNTIME")
session="$tmp/permission-client.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- approved' \
  sf_test_run permission "$session" \
    '{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}' \
    >"$stream" || fail 'client permission approval failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  ($events | map(select(.type == "tool_result"))[0].exit_code) == 0
' <"$stream" >/dev/null || fail 'client permission was not requested explicitly'
jq -e -s 'all(.[]; .type != "_tool_permission_request" and
  .type != "_tool_permission_response")' "$session" >/dev/null ||
  fail 'permission exchange became durable'

# A completed failing post hook remains before the known outcome and durable error.
typeset post_fail="$tmp/post-fail"
cat >"$post_fail" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- 'post failure context'
print -rn -u2 -- 'post failure display'
exit 10
ZSH
chmod +x "$post_fail"
SF_TEST_RUNTIME=$(jq -c --arg hook "$post_fail" '
  .harness.permission_request=[] |
  .harness.post_tool_use=[{command:$hook,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
session="$tmp/post-failure.jsonl"
sf_test_session "$session"
integer post_status=0
SF_TEST_BACKEND_TOOL_CALL=1 sf_test_run post "$session" >"$stream" || post_status=$?
(( post_status == 1 )) || fail 'failing post hook did not fail the turn'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-3] | .type == "hook_result" and .lifecycle == "post_tool_use" and
    .exit_code == 10 and .model_text == "post failure context" and
    .user_text == "post failure display") and
  ($events[-2] | .type == "tool_result" and .id == "call_1" and .exit_code == 0) and
  ($events[-1] | .type == "error" and (.user_text | contains("post_tool_use")))
' <"$stream" >/dev/null || fail 'post failure lost or reordered the known outcome'
assert_canonical_session "$session"

# A sandboxed tool needs fence on PATH when it runs. ZDOTDIR keeps a user's
# .zshenv from restoring PATH.
SF_TEST_RUNTIME=$(jq -c '.harness.post_tool_use=[] | .harness.sandbox=true' <<<"$SF_TEST_RUNTIME")
typeset no_fence="$tmp/no-fence"
mkdir "$no_fence"
ln -s "$commands[jq]" "$commands[zsh]" "$no_fence/"
session="$tmp/sandbox-missing.jsonl"
sf_test_session "$session"
ZDOTDIR=$no_fence PATH="$no_fence:/usr/bin:/bin" SF_TEST_BACKEND_TOOL_CALL=1 \
  sf_test_run sandbox "$session" >"$stream" 2>/dev/null || true
jq -eRn '[inputs | fromjson][-1] |
  .type == "error" and (.user_text | contains("sandboxing requires fence"))
' <"$stream" >/dev/null || fail 'sandboxed tool ran without fence'

# A sandbox violation annotates the model text of a failing tool, and only that.
mkdir "$tmp/bin"
typeset fence="$tmp/bin/fence"
typeset fence_arguments="$tmp/fence-arguments"
cat >"$fence" <<'ZSH'
#!/usr/bin/env zsh
log=''
print -rl -- "$@" >"$FENCE_ARGUMENTS"
while (( $# )); do
  case $1 in
    --fence-log-file) log=$2; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
[[ -z $log ]] || print -r -- '[fence:logstream] ✗ file-write-create /etc/denied' >"$log"
exec "$@"
ZSH
chmod +x "$fence"
export FENCE_ARGUMENTS=$fence_arguments PATH="$tmp/bin:$PATH"
session="$tmp/sandbox-denied.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- output; exit 3' \
  sf_test_run sandbox "$session" >"$stream" || fail 'sandbox denial turn failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 3 and .user_text == "shell\noutput\nexit 3" and
  .model_text == "output\nexit 3\n\n<sandbox_notice>A denial was detected during this tool call. This does not necessarily mean the tool failed.</sandbox_notice>"
' <"$stream" >/dev/null || fail 'sandbox denial did not annotate the model text'
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
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- output' \
  sf_test_run sandbox "$session" >"$stream" || fail 'tolerated denial turn failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 0 and .model_text == "output\nexit 0"
' <"$stream" >/dev/null || fail 'a succeeding tool was annotated'

# A sandboxed tool starts clean apart from its declared names.
SF_TEST_RUNTIME=$(jq -c '.harness.tools[0].manifest.environment=["DECLARED"]' \
  <<<"$SF_TEST_RUNTIME")
session="$tmp/sandbox-env.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=$env_command \
  sf_test_run sandbox "$session" >"$stream" || fail 'sandboxed environment turn failed'
jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0].model_text ==
  "declared-file unset unset\nexit 0"' <"$stream" >/dev/null ||
  fail 'sandboxed tool saw values beyond its declared names'

print -r -- ok
