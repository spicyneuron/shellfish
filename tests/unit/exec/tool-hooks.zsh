#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/main.zsh hooks.zsh

typeset stream
sf_test_tmp exec-tool-hooks
export XDG_STATE_HOME="$tmp/state"
export TEST_OUTPUT_DIR="$tmp/hook-output"
mkdir "$TEST_OUTPUT_DIR"
typeset system_file="$tmp/system.md"
typeset request_capture="$tmp/request.json"
printf 'frozen system\n' >"$system_file"

sf_test_runtime "$system_file"
export SF_TEST_BACKEND_DELAY=0
export SF_TEST_BACKEND_REQUEST="$request_capture"

# pre_tool_use and post_tool_use scripts receive canonical envelopes. A nonzero
# tool exit remains an executed result, and stderr remains a transient hook display.
typeset pre_observe="$tmp/pre-observe"
cat >"$pre_observe" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 1 && $1 == pre_tool_use ]]
input=$(cat)
call_id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$TEST_OUTPUT_DIR/pre-$call_id"
print -rn -u2 -- "pre-local-$call_id"
ZSH
chmod +x "$pre_observe"
typeset post_observe="$tmp/post-observe"
cat >"$post_observe" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 1 && $1 == post_tool_use ]]
[[ $SHELLFISH_TURN_ID == 1 && $SHELLFISH_SESSION_ID == tool-observe &&
  $SHELLFISH_MODEL == test-model && $PROJECT_DIR == $PWD ]]
input=$(cat)
call_id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$TEST_OUTPUT_DIR/post-$call_id"
print -rn -u2 -- "post-local-$call_id"
ZSH
chmod +x "$post_observe"
SF_TEST_RUNTIME=$(jq -c --arg pre "$pre_observe" --arg post "$post_observe" '
  .harness.pre_tool_use=[$pre] | .harness.post_tool_use=[$post] |
  .harness.sandbox=false
' <<<"$SF_TEST_RUNTIME")
typeset observe_session="$tmp/tool-observe.jsonl"
sf_test_session "$observe_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  SF_TEST_BACKEND_TOOL_COMMAND="printf 'line\\n\\n'; exit 7" \
  sf_test_turn observe "$observe_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result")) |
    map({exit_code,content})) ==
    [{exit_code:7,content:"line\n\n"},
     {exit_code:7,content:"line\n\n"}] and
  ($events | map(select(.type == "_hook_display" and .complete) | {hook,script:(.script|split("/")[-1]),text})) ==
    [{hook:"pre_tool_use",script:"pre-observe",text:"pre-local-call_1"},
     {hook:"post_tool_use",script:"post-observe",text:"post-local-call_1"},
     {hook:"pre_tool_use",script:"pre-observe",text:"pre-local-call_2"},
     {hook:"post_tool_use",script:"post-observe",text:"post-local-call_2"}]
' >/dev/null
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:"printf '\''line\\n\\n'\''; exit 7"}}' \
  "$TEST_OUTPUT_DIR/pre-call_1" >/dev/null
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:"printf '\''line\\n\\n'\''; exit 7"},
  tool_response:{content:"line\n\n",exit_code:7}}' \
  "$TEST_OUTPUT_DIR/post-call_1" >/dev/null
jq -e '
  .messages[-2].role == "tool_result" and
  .messages[-1].role == "tool_result"
' "$request_capture" >/dev/null

# A pre-tool denial creates an ordinary result; later sibling calls still run
# and post-tool observers see every committed result.
typeset pre_deny="$tmp/pre-deny"
cat >"$pre_deny" <<'ZSH'
#!/usr/bin/env zsh
call_id=$(jq -r '.tool_use_id')
print -r -- "$call_id" >>"$TEST_OUTPUT_DIR/pre-calls"
[[ $SHELLFISH_TURN_ID == 1 && $SHELLFISH_SESSION_ID == tool-deny(|-fallback) &&
  $SHELLFISH_MODEL == test-model && $PROJECT_DIR == $PWD ]] || exit 1
[[ $call_id != call_2 ]] || { [[ -n $NO_FEEDBACK ]] || print -rn -- 'first reason'; exit 10; }
ZSH
chmod +x "$pre_deny"
typeset pre_later="$tmp/pre-later"
cat >"$pre_later" <<'ZSH'
#!/usr/bin/env zsh
call_id=$(jq -r '.tool_use_id')
print -r -- "$call_id" >>"$TEST_OUTPUT_DIR/pre-later-calls"
[[ $call_id != call_2 ]] || { [[ -n $NO_FEEDBACK ]] || print -rn -- 'second reason'; exit 11; }
ZSH
chmod +x "$pre_later"
typeset pre_never="$tmp/pre-never"
cat >"$pre_never" <<'ZSH'
#!/usr/bin/env zsh
jq -r '.tool_use_id' >>"$TEST_OUTPUT_DIR/pre-never-calls"
ZSH
chmod +x "$pre_never"
typeset post_log="$tmp/post-log"
cat >"$post_log" <<'ZSH'
#!/usr/bin/env zsh
jq -r '[.tool_use_id,(.tool_response.exit_code | tostring)] | join("|")' \
  >>"$TEST_OUTPUT_DIR/post-calls"
ZSH
chmod +x "$post_log"
SF_TEST_RUNTIME=$(jq -c --arg pre "$pre_deny" --arg later "$pre_later" \
  --arg never "$pre_never" --arg post "$post_log" '
  .harness.pre_tool_use=[$pre,$later,$never] | .harness.post_tool_use=[$post]
' <<<"$SF_TEST_RUNTIME")
typeset deny_session="$tmp/tool-deny.jsonl"
sf_test_session "$deny_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=3 \
  sf_test_turn deny "$deny_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result") | .exit_code)) == [0,126,0] and
  ($events | map(select(.role == "tool_result"))[1].content) ==
    "first reason\nsecond reason"
' >/dev/null
[[ $(<$TEST_OUTPUT_DIR/pre-calls) == $'call_1\ncall_2\ncall_3' ]]
[[ $(<$TEST_OUTPUT_DIR/pre-later-calls) == $'call_1\ncall_2\ncall_3' ]]
[[ $(<$TEST_OUTPUT_DIR/pre-never-calls) == $'call_1\ncall_3' ]]
[[ $(<$TEST_OUTPUT_DIR/post-calls) == \
  $'call_1|0\ncall_2|126\ncall_3|0' ]]

typeset fallback_session="$tmp/tool-deny-fallback.jsonl"
sf_test_session "$fallback_session"
stream=$(NO_FEEDBACK=1 SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  sf_test_turn deny "$fallback_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson | select(.role == "tool_result")][1] as $result |
  $result.exit_code == 126 and
  ($result.content | contains("pre-deny"))
' >/dev/null
