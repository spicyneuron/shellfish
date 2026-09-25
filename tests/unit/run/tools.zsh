#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-tool-contract
mkdir "$tmp/host-temp"
export TMPDIR="$tmp/host-temp" TMPPREFIX="$tmp/manifest-prefix"
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0
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
SF_TEST_BACKEND_TOOL_CALL=1 \
  SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- "$TMPDIR|$TMPPREFIX"' \
  sf_test_run temp "$temp_session" >"$temp_stream" || fail 'tool temp environment turn failed'
jq -eRn --arg expected "${TMPDIR:A}|${TMPDIR:A}/zsh" '
  [inputs | fromjson | select(.type == "tool_result")][0].model_text ==
    ($expected + "\nexit 0")
' <"$temp_stream" >/dev/null || fail 'tool did not receive the host temp environment'

# Hooks receive all profile and .env values; tools receive only declared names.
typeset env_config="$XDG_CONFIG_HOME/shellfish" env_hook="$tmp/env-hook" env_seen="$tmp/env-seen"
typeset env_session="$tmp/env.jsonl" env_stream="$tmp/env.stream" base_profile=$SF_TEST_PROFILE
typeset env_command='print -rn -- "${DECLARED-unset} ${UNDECLARED-unset} ${EXPORTED-unset} ${SHELLFISH_SHARE_DIR-unset}"'
mkdir -p "$env_config"
print -rl -- DECLARED=declared-file UNDECLARED=undeclared-file >"$env_config/.env"
cat >"$env_hook" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- "${UNDECLARED-unset} ${SHELLFISH_SHARE_DIR-unset}" >"$ENV_SEEN"
ZSH
chmod +x "$env_hook"
export ENV_SEEN=$env_seen EXPORTED=exported
sf_test_shell_tool '.environment=["DECLARED"]'
SF_TEST_PROFILE=$(jq -c --arg hook "$env_hook" '
  .hooks.post_tool_use=[$hook] |
  .env={DECLARED:"declared-profile",UNDECLARED:"undeclared-profile",EXPORTED:"ignored"}
' \
  <<<"$SF_TEST_PROFILE")
sf_test_session "$env_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=$env_command \
  sf_test_run env "$env_session" >"$env_stream" || fail 'tool environment turn failed'
jq -eRn --arg share "$SF_SHARE" '[inputs | fromjson | select(.type == "tool_result")][0].model_text ==
  ("declared-profile unset exported " + $share + "\nexit 0")' <"$env_stream" >/dev/null ||
  fail 'unsandboxed tool did not receive profile env with declared-name filtering'
assert_equal "undeclared-profile $SF_SHARE" "$(<$env_seen)" \
  'hook did not receive profile env'
SF_TEST_PROFILE=$base_profile

# Tool manifests are read on each run, so an edit after creation takes effect.
typeset live_session="$tmp/live-manifest.jsonl"
sf_test_session "$live_session"
sf_test_shell_tool '.environment=["TMPPREFIX"] | .description="edited after creation"'
SF_TEST_BACKEND_REQUEST="$tmp/live-request.json" sf_test_run live "$live_session" >/dev/null ||
  fail 'live manifest turn failed'
jq -e '.tools[0].description | startswith("edited after creation")' \
  "$tmp/live-request.json" >/dev/null || fail 'tool manifest was not read live'
sf_test_shell_tool '.environment=["TMPPREFIX"]'

# Tool temp cannot redirect the next call's core-owned input write.
typeset input_target="$tmp/tool-input-target" input_session="$tmp/tool-input.jsonl"
typeset input_stream="$tmp/tool-input.stream"
sf_test_session "$input_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  SF_TEST_BACKEND_TOOL_COMMAND="ln -sf ${(q)input_target} \"\$TMPDIR/input\"" \
  sf_test_run input "$input_session" >"$input_stream" || fail 'tool input isolation turn failed'
[[ ! -e $input_target ]] || fail 'tool temp redirected a later input write'

# Pre-tool denial refuses with its reason without reaching the later hook,
# preserves sibling calls, and still reaches post hooks.
typeset pre="$tmp/pre" later="$tmp/pre-later" post="$tmp/post"
typeset hook_dir="$tmp/hook-inputs" tool_marker="$tmp/tool-ran"
mkdir "$hook_dir"
cat >"$pre" <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$HOOK_DIR/pre-$id"
if [[ $id == call_1 ]]; then
  print -r -u3 -- '{"user_text":"pre display","model_text":"pre context","state":[{"name":"pre/call_1","value":true}],"action":"deny","reason":"pre denied"}'
else
  :
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
print -rn -u3 -- "{\"user_text\":\"post $id\",\"state\":[{\"name\":\"post/$id\",\"value\":true}]}"
ZSH
chmod +x "$pre" "$later" "$post"
export HOOK_DIR=$hook_dir TOOL_MARKER=$tool_marker
SF_TEST_PROFILE=$(jq -c --arg pre "$pre" --arg later "$later" --arg post "$post" '
  .hooks.pre_tool_use=[$pre, $later] |
  .hooks.post_tool_use=[$post]
' <<<"$SF_TEST_PROFILE")
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
  tool_input:{command:$command},tool_response:{stdout:"",stderr:"pre denied",exit_code:126}}' \
  --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  "$hook_dir/post-call_1" >/dev/null || fail 'post hook did not receive the denial outcome'
assert_equal call_2 "$(<$hook_dir/later)" 'deny reached the later hook'
assert_equal ran "$(<$tool_marker)" 'pre-tool denial did not preserve the sibling call'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("state","hook_result","tool_result")) |
    if .type == "state" then [.type,.name]
    elif .type == "hook_result" then [.type,.lifecycle]
    else [.type,.id,.exit_code] end] == [
      ["state","pre/call_1"],
      ["hook_result","pre_tool_use"],
      ["state","post/call_1"],
      ["hook_result","post_tool_use"],
      ["tool_result","call_1",126],
      ["state","post/call_2"],
      ["hook_result","post_tool_use"],
      ["tool_result","call_2",0]
    ] and
  ($events | map(select(.type == "hook_result"))[0] |
    .model_text == "pre context" and .user_text == "pre display") and
  ($events | map(select(.type == "tool_result"))[0].model_text | contains("pre denied")) and
  ($events | map(select(.type == "_draft" and .name == "shell"))[1].user_text) ==
    "shell\n" + $command and
  ($events | map(select(.type == "tool_result"))[1] |
    .user_text == "shell\n" + $command + "\noutput\nexit 0" and
    .model_text == "output\nexit 0")
' --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  <"$stream" >/dev/null || fail 'tool lifecycle ordering or rendering was wrong'
assert_canonical_session "$session"

# Permission hooks receive the request and may allow or deny.
typeset permission="$tmp/permission" permission_input="$tmp/permission-input"
cat >"$permission" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 2 && $1 == shell && $2 == call_1 ]] || exit 2
input=$(cat)
print -rn -- "$input" >"$PERMISSION_INPUT"
print -rn -u3 -- '{"state":[{"name":"permission/state","value":true}],"action":"allow","user_text":"review display","model_text":"review context"}'
ZSH
chmod +x "$permission"
export PERMISSION_INPUT=$permission_input
SF_TEST_PROFILE=$(jq -c --arg hook "$permission" '
  .hooks.pre_tool_use=[] | .hooks.post_tool_use=[] |
  .sandbox=true |
  .hooks.permission_request=[$hook]
' <<<"$SF_TEST_PROFILE")
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
    .lifecycle == "permission_request" and
    .model_text == "review context" and .user_text == "review display") and
  ($events | map(select(.type == "tool_result"))[0].exit_code) == 0
' <"$stream" >/dev/null || fail 'permission allow produced the wrong records'

cat >"$permission" <<'ZSH'
#!/usr/bin/env zsh
cat >"$PERMISSION_INPUT"
print -rn -u3 -- '{"action":"deny","reason":"review denied"}'
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

# If every hook defers, approval falls back to the client.
typeset defer_one="$tmp/defer-one" defer_two="$tmp/defer-two"
cat >"$defer_one" <<'ZSH'
#!/usr/bin/env zsh
cat >"$PERMISSION_INPUT"
print -r -u3 -- '{"user_text":"reviewed","finalize":true}'
ZSH
cat >"$defer_two" <<'ZSH'
#!/usr/bin/env zsh
[[ -s $PERMISSION_INPUT ]] || exit 2
cat >/dev/null
ZSH
chmod +x "$defer_one" "$defer_two"
SF_TEST_PROFILE=$(jq -c --arg one "$defer_one" --arg two "$defer_two" \
  '.hooks.permission_request=[$one,$two]' <<<"$SF_TEST_PROFILE")
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
  ($events | map(select(.type == "_tool_permission_request"))[0].preview) ==
    "print -rn -- approved" and
  ($events | map(select(.type == "hook_result")) | any(.user_text == "reviewed")) and
  ($events | map(select(.type == "tool_result"))[0].exit_code) == 0
' <"$stream" >/dev/null || fail 'client permission was not requested explicitly'
jq -e -s 'all(.[]; .type != "_tool_permission_request" and
  .type != "_tool_permission_response")' "$session" >/dev/null ||
  fail 'permission exchange became durable'

# A failing post hook keeps its finalized section before the known outcome and durable error.
typeset post_fail="$tmp/post-fail"
cat >"$post_fail" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -u3 -- '{"user_text":"post failure display","model_text":"post failure context","finalize":true}'
exit 3
ZSH
chmod +x "$post_fail"
SF_TEST_PROFILE=$(jq -c --arg hook "$post_fail" '
  .hooks.permission_request=[] |
  .hooks.post_tool_use=[$hook] |
  .sandbox=false
' <<<"$SF_TEST_PROFILE")
session="$tmp/post-failure.jsonl"
sf_test_session "$session"
integer post_status=0
SF_TEST_BACKEND_TOOL_CALL=1 sf_test_run post "$session" >"$stream" || post_status=$?
(( post_status == 1 )) || fail 'failing post hook did not fail the turn'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-3] | .type == "hook_result" and .lifecycle == "post_tool_use" and
    .model_text == "post failure context" and
    .user_text == "post failure display") and
  ($events[-2] | .type == "tool_result" and .id == "call_1" and .exit_code == 0) and
  ($events[-1] | .type == "error" and (.user_text | contains("post_tool_use")))
' <"$stream" >/dev/null || fail 'post failure lost or reordered the known outcome'
assert_canonical_session "$session"

# A sandboxed tool needs fence on PATH when it runs. ZDOTDIR keeps a user's
# .zshenv from restoring PATH.
SF_TEST_PROFILE=$(jq -c '.hooks.post_tool_use=[] | .sandbox=true' <<<"$SF_TEST_PROFILE")
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
  .exit_code == 3 and .user_text == "shell\nprint -rn -- output; exit 3\noutput\nexit 3" and
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
sf_test_shell_tool '.environment=["DECLARED"]'
SF_TEST_PROFILE=$(jq -c '.env={DECLARED:"sandbox-profile",UNDECLARED:"hidden"}' \
  <<<"$SF_TEST_PROFILE")
session="$tmp/sandbox-env.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=$env_command \
  sf_test_run sandbox "$session" >"$stream" || fail 'sandboxed environment turn failed'
jq -eRn --arg share "$SF_SHARE" '[inputs | fromjson | select(.type == "tool_result")][0].model_text ==
  ("sandbox-profile unset unset " + $share + "\nexit 0")' <"$stream" >/dev/null ||
  fail 'sandboxed tool saw values beyond its declared names'

# A tool streams user text and state, then settles once at exit. Stdout fills
# the model text it did not write. A tool ignores finalize, and an action is invalid.
typeset protocol="$tmp/protocol"
cat >"$protocol" <<'ZSH'
#!/usr/bin/env zsh
case $(jq -r .command) in
  final)
    print -r -u3 -- '{"user_text":"working","state":[{"name":"tool/a","value":1}]}'
    print -r -u3 -- '{"user_text":"shown","finalize":true,"user_preview_lines":"full","state":[{"name":"tool/b","value":2}]}'
    print -rn -- seen
    exit 4
    ;;
  hint) print -r -u3 -- '{"user_preview_lines":3}'; print -rn -- plain ;;
  action)
    print -r -u3 -- '{"state":[{"name":"tool/before-error","value":true}]}'
    print -r -u3 -- '{"action":"deny"}'
    ;;
  stream)
    print -r -u3 -- '{"state":[{"name":"tool/live","value":true}]}'
    : >"$TOOL_MARKER"
    sleep 30
    ;;
  huge) jq -cn '{user_text:("x" * 70000)}' >&3 ;;
esac
ZSH
chmod +x "$protocol"
sf_test_shell_tool . "$protocol"
SF_TEST_PROFILE=$(jq -c '.sandbox=false' <<<"$SF_TEST_PROFILE")
session="$tmp/protocol.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=final \
  sf_test_run protocol "$session" >"$stream" || fail 'protocol tool turn failed'
jq -eRn '
  [inputs | fromjson | select(.type | IN("_draft","state","tool_result"))] ==
    [{type:"_draft",id:"call_1",name:"shell",user_text:"shell\nfinal"},
     {type:"state",name:"tool/a",value:1},
     {type:"_draft",id:"call_1",name:"shell",user_text:"working"},
     {type:"state",name:"tool/b",value:2},
     {type:"_draft",id:"call_1",name:"shell",user_text:"shown",user_preview_lines:"full"},
     {type:"tool_result",id:"call_1",name:"shell",input:{command:"final"},exit_code:4,
      user_text:"shown",model_text:"seen",user_preview_lines:"full"}]
' <"$stream" >/dev/null || fail 'tool user text or output settled wrong'
assert_canonical_session "$session"

# The result inherits the last preview hint.
session="$tmp/protocol-hint.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=hint \
  sf_test_run protocol "$session" >"$stream" || fail 'hinted tool turn failed'
jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0] |
  .user_text == "shell\nhint\nplain" and .model_text == "plain" and
  .user_preview_lines == 3' <"$stream" >/dev/null || fail 'shortcut lost its preview hint'

session="$tmp/protocol-action.jsonl"
sf_test_session "$session"
if SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=action \
    sf_test_run protocol "$session" >"$stream" 2>/dev/null; then
  fail 'a tool action was accepted'
fi
jq -eRn '[inputs | fromjson][-1] | .type == "error" and
  (.user_text | contains("invalid control"))' <"$stream" >/dev/null ||
  fail 'a tool action was not reported'
jq -e -s 'map(select(.type == "state")) ==
  [{type:"state",name:"tool/before-error",value:true}]' "$session" >/dev/null ||
  fail 'invalid control lost previously accepted tool state'

# State is durable while the tool is running and remains so after interruption.
typeset live_marker="$tmp/tool-live"
session="$tmp/protocol-stream.jsonl"
sf_test_session "$session"
jq -cn '{type:"user",content:[{type:"text",text:"protocol"}]}' |
  SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=stream \
  TOOL_MARKER=$live_marker "$ROOT/bin/shellfish" run --jsonl --session "$session" \
  >"$stream" &
integer live_pid=$! live_waited=0 live_status=0
while (( live_waited++ < 100 )) && [[ ! -e $live_marker ]]; do sleep 0.02; done
(( live_waited <= 100 )) || fail 'tool did not reach its wait'
live_waited=0
while (( live_waited++ < 100 )) && ! jq -e -s \
    'any(.[]; .type == "state" and .name == "tool/live")' "$session" \
    >/dev/null 2>&1; do sleep 0.02; done
(( live_waited <= 100 )) || fail 'tool state was not committed while running'
kill -TERM "$live_pid" 2>/dev/null
wait "$live_pid" || live_status=$?
(( live_status == 143 )) || fail 'interrupted tool returned the wrong status'
jq -e -s 'any(.[]; .type == "state" and .name == "tool/live")' \
  "$session" >/dev/null || fail 'interruption lost committed tool state'
assert_canonical_session "$session"

# A line beyond the capture limit fails the call, not the turn.
session="$tmp/protocol-huge.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=huge \
  sf_test_run protocol "$session" >"$stream" || fail 'oversized line failed the turn'
jq -eRn '[inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 1 and .model_text == "tool result exceeds capture limit"' \
  <"$stream" >/dev/null || fail 'oversized line did not fail the call'

print -r -- ok
