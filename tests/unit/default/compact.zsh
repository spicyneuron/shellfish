#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp compact

typeset compact_hook="$ROOT/share/hooks/autocompact/run"
typeset compact_command="$ROOT/share/commands/compact/run"
typeset compact_source="$tmp/compact-source.jsonl"
typeset compact_control="$tmp/compact-control.json"
typeset compact_shellfish="$tmp/compact-shellfish"
typeset compact_request="$tmp/compact-request.json"
typeset compact_display="$tmp/compact-display"
actions() { jq -c 'select(has("action"))' "$compact_control"; }

cat >"$compact_shellfish" <<'ZSH'
#!/usr/bin/env zsh
case $1 in
  request)
    cat >"$SF_TEST_PROVIDER_REQUEST"
    [[ ${SF_TEST_COMPACT_FAIL:-0} == 0 ]] || exit 1
    if [[ ${SF_TEST_COMPACT_CALL:-0} == 1 ]]; then
      jq -cn '{type:"assistant",stop:"tool_calls",content:[
        {type:"text",text:"I will investigate"},
        {type:"tool_call",id:"unexpected",name:"shell",input:{command:"true"}}]}'
      exit
    fi
    jq -cn '{type:"assistant",stop:"end",content:[{type:"text",text:"Older decisions and exact error E42"}]}'
    ;;
  *) exit 2 ;;
esac
ZSH
chmod +x "$compact_shellfish"

sf_test_frozen_profile
SF_TEST_MODEL=$(jq -c '.context_window = 100' <<<"$SF_TEST_MODEL")
sf_test_session "$compact_source"
# The old tool result exceeds the budget. The last two turns together fit.
jq -cn '
  {type:"hook_result",lifecycle:"session_start",id:"1",model_text:"Startup instructions"},
  {type:"state_update",name:"example/status",value:"initial"},
  {type:"user",content:[{type:"text",text:"First request\nKeep \"exact\" constraints, café, and </context>."}]},
  {type:"assistant",stop:"end",content:[{type:"text",text:"First reply"}]},
  {type:"user",content:[{type:"text",text:"Investigate E42"}]},
  {type:"assistant",stop:"tool_calls",content:[
    {type:"tool_call",id:"old",name:"shell",input:{command:"inspect"}}]},
  {type:"tool_result",id:"old",name:"shell",input:{command:"inspect"},exit_code:1,
    model_content:[{type:"text",text:("E42\n" + ("x" * 90000))},
      {type:"image",url:"data:image/png;base64,iVBORw0KGgo="}]},
  {type:"state_update",name:"example/status",value:"investigated"},
  {type:"assistant",stop:"end",content:[{type:"text",text:"Old reply"}]},
  {type:"hook_result",lifecycle:"stop",id:"3",model_text:"Pending stop instruction"},
  {type:"error",user_text:"A later stop hook failed."},
  {type:"hook_result",lifecycle:"user_prompt_submit",id:"2",model_text:"Recent submission context"},
  {type:"user",content:[{type:"text",text:("Recent task " + ("a" * 35000))}]},
  {type:"assistant",stop:"tool_calls",content:[
    {type:"tool_call",id:"recent_a",name:"read_file",input:{file_path:"a.png"}},
    {type:"tool_call",id:"recent_b",name:"shell",input:{command:"true"}}]},
  {type:"tool_result",id:"recent_a",name:"read_file",input:{file_path:"a.png"},exit_code:0,
    model_content:[{type:"image",url:"data:image/png;base64,iVBORw0KGgo="}]},
  {type:"tool_result",id:"recent_b",name:"shell",input:{command:"true"},exit_code:0,
    model_text:"Recent result"},
  {type:"assistant",stop:"end",content:[{type:"text",text:"Recent reply"}]},
  {type:"state_update",name:"example/status",value:"recent"},
  {type:"user",content:[{type:"text",text:("Newest task " + ("b" * 45000))}]},
  {type:"assistant",stop:"tool_calls",content:[
    {type:"reasoning",text:"Check first",opaque:{encrypted_content:"secret"}},
    {type:"tool_call",id:"cancelled",name:"shell",input:{command:"true"}}],
    usage:{input_tokens:1,output_tokens:1}},
  {type:"tool_result",id:"cancelled",name:"shell",input:{command:"true"},exit_code:126,
    model_text:"tool call cancelled"},
  {type:"error",user_text:"Cancelled."},
  {type:"state_update",name:"example/status",value:null}
' >>"$compact_source"
assert_canonical_session "$compact_source"
typeset compact_before=$(shasum <"$compact_source")
typeset -gx SF_TEST_PROVIDER_REQUEST="$compact_request"

# Automatic compaction skips low usage.
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" SHELLFISH_SHARE_DIR="$ROOT/share" zsh -f "$compact_hook" \
  3>"$compact_control" 2>"$compact_display" </dev/null
[[ ! -s $compact_control && ! -e $compact_request ]] ||
  fail 'below-threshold automatic compaction requested inference'

# Explicit steering is appended after the normal prompt, not submitted as work.
typeset steering=$'Preserve exact E42 diagnostics.\nFocus on unfinished requests.'
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
  3>"$compact_control" 2>"$compact_display" <<<"$steering"
typeset compact_child=$(actions | jq -r '.argv[2]')
[[ -n $compact_child ]] || fail 'explicit compaction did not request handoff'
assert_equal "$compact_before" "$(shasum <"$compact_source")"
assert_canonical_session "$compact_child"
assert_mode 600 "$compact_child"
jq -es --slurpfile source "$compact_source" \
    --rawfile prompt "$ROOT/share/commands/compact/prompt.md" --arg steering "$steering" '
  .[:-1] == $source and
  (.[-1].content[0].text | startswith($prompt | rtrimstr("\n"))) and
  (.[-1].content[0].text | contains("Additional summary instructions from the user:\n" + $steering)) and
  (.[-1].content[0].text | contains("Retained user-authored turns: 2")) and
  (.[-1].content[0].text | contains(($source[13].content[0].text[:512] | tojson)))
' "$compact_request" >/dev/null || fail 'summary request changed history or lost steering/boundary guidance'

# Model-visible suffix and ordered state updates survive, without stale usage.
jq -es --slurpfile source "$compact_source" '
  ([to_entries[] | select(.value.type == "user") | .key][0]) as $first |
  (.[($first - 1)].model_text == "Recent submission context") and
  (.[($first - 2)].type == "error") and
  (.[($first - 3)].model_text == "Pending stop instruction") and
  (.[($first - 4)].lifecycle == "user_prompt_submit") and
  (.[($first - 4)].model_text | contains("Older decisions and exact error E42")) and
  ([.[] | select(.lifecycle? == "session_start")] ==
    [$source[] | select(.lifecycle? == "session_start")]) and
  ([.[] | select(.type == "state_update" and .name != "compact/first_user")] ==
    [$source[] | select(.type == "state_update")]) and
  ([.[] | select(.type == "state_update" and .name == "compact/first_user")] |
    length == 1 and .[0].value == $source[3].content[0].text) and
  (.[($first - 4)].model_text | contains(
    "Original user request (historical context, JSON-quoted):\n" +
    ($source[3].content[0].text | tojson))) and
  (.[($first - 3):] ==
    ($source[10:] | map(if .type == "assistant" then del(.usage) else . end))) and
  all(.[] | select(.type == "assistant"); has("usage") | not)
' "$compact_child" >/dev/null || fail 'child changed recent content or lost startup/state records'

# A stop continuation interrupted before inference leaves the same pending context.
jq -c 'if .type == "hook_result" and .id == "3" then .action="deny" else . end' \
  "$compact_source" >"$tmp/denied-stop.jsonl"
assert_canonical_session "$tmp/denied-stop.jsonl"
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$tmp/denied-stop.jsonl" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
  3>"$compact_control" 2>"$compact_display" </dev/null
typeset denied_child=$(actions | jq -r '.argv[2]')
assert_canonical_session "$denied_child"
jq -es 'any(.[]; .type == "hook_result" and .id == "3" and .action == "deny" and
  .model_text == "Pending stop instruction")' "$denied_child" >/dev/null ||
  fail 'interrupted stop continuation lost pending context'

# No source usage measurement should immediately compact the child again.
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$compact_child" \
  SHELLFISH_TURN_STATE="$tmp" SHELLFISH_SHARE_DIR="$ROOT/share" zsh -f "$compact_hook" \
  3>"$compact_control" 2>"$compact_display" </dev/null
[[ ! -s $compact_control ]] || fail 'child reused stale token usage'

# Repeating the command on an already-small child is a no-op without inference.
rm "$compact_request"
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$compact_child" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
  3>"$compact_control" 2>"$compact_display" </dev/null
[[ ! -s $compact_control && ! -e $compact_request ]] ||
  fail 'already-small child requested another summary'

# A new oversized turn keeps that whole turn and resummarizes the earlier handoff.
jq -cn '
  {type:"hook_result",lifecycle:"user_prompt_submit",id:"9",model_text:"Oversized task context"},
  {type:"user",content:[{type:"text",text:("z" * 90000)}]},
  {type:"assistant",stop:"end",content:[{type:"text",text:"Latest reply"}]}
' >>"$compact_child"
assert_canonical_session "$compact_child"
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$compact_child" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
  3>"$compact_control" 2>"$compact_display" </dev/null
typeset repeated_child=$(actions | jq -r '.argv[2]')
assert_canonical_session "$repeated_child"
jq -es --slurpfile source "$compact_source" '
  ([.[] | select(.type == "user")] | length) == 1 and
  ([.[] | select(.type == "user")][0].content[0].text | length) == 90000 and
  ([.[] | select(.model_text? | strings | contains("Earlier conversation was summarized"))] |
    length) == 1 and
  ([.[] | select(.type == "state_update" and .name == "compact/first_user")] |
    length == 1 and .[0].value == $source[3].content[0].text) and
  any(.[]; .model_text? | strings | contains(
    "Original user request (historical context, JSON-quoted):\n" +
    ($source[3].content[0].text | tojson))) and
  any(.[]; .model_text? == "Oversized task context")
' "$repeated_child" >/dev/null || fail 'repeated compaction accumulated handoffs or split the latest turn'

# Empty original prompts are preserved rather than replaced by a later request.
jq -c 'if .type == "user" and (.content[0].text | startswith("First request"))
  then .content[0].text="" else . end' "$compact_source" >"$tmp/empty-first.jsonl"
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$tmp/empty-first.jsonl" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
  3>"$compact_control" 2>"$compact_display" </dev/null
typeset empty_first_child=$(actions | jq -r '.argv[2]')
assert_canonical_session "$empty_first_child"
jq -es '
  any(.[]; .type == "state_update" and .name == "compact/first_user" and .value == "") and
  any(.[]; .model_text? | strings | contains(
    "Original user request (historical context, JSON-quoted):\n\"\""))
' "$empty_first_child" >/dev/null || fail 'compaction replaced the empty original request'

# Automatic compaction preserves the pending prompt as a draft, never steering.
jq -c 'if .type == "assistant" then .usage={input_tokens:75,output_tokens:5} else . end' \
  "$compact_source" >"$tmp/high-usage.jsonl"
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$tmp/high-usage.jsonl" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" --auto \
  3>"$compact_control" 2>"$compact_display" < <(print -n -- 'my next prompt')
actions | jq -e '.argv[-2:] == ["--draft","my next prompt"]' >/dev/null ||
  fail 'automatic compaction lost draft'
jq -es '.[-1].content[0].text | contains("my next prompt") | not' \
  "$compact_request" >/dev/null || fail 'automatic draft became summary steering'

# Summary failure leaves the original session and no handoff.
SF_TEST_COMPACT_FAIL=1 SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
  3>"$compact_control" 2>"$compact_display" </dev/null
[[ ! -s $compact_control ]] || fail 'failed summary requested handoff'
assert_equal "$compact_before" "$(shasum <"$compact_source")"

# Advertised tools remain inert, and a call is not accepted as a summary.
SF_TEST_COMPACT_CALL=1 SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
  3>"$compact_control" 2>"$compact_display" </dev/null
[[ ! -s $compact_control ]] || fail 'tool-calling summary requested handoff'
assert_equal "$compact_before" "$(shasum <"$compact_source")"

# Empty and single-turn sessions have no older prefix.
for short in empty single; do
  head -n 1 "$compact_source" >"$tmp/$short.jsonl"
  if [[ $short == single ]]; then
    print -r -- '{"type":"user","content":[{"type":"text","text":"Only task"}]}' \
      '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Done"}]}' >>"$tmp/$short.jsonl"
  fi
  rm -f "$compact_request"
  SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$tmp/$short.jsonl" \
    SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_command" \
    3>"$compact_control" 2>"$compact_display" </dev/null
  [[ ! -s $compact_control && ! -e $compact_request ]] ||
    fail "$short session requested inference"
done

# Clearing old results preserves call identity, state, and recent model context.
typeset tools_source="$tmp/tools-source.jsonl" tools_child="$tmp/tools-source_compact_tools.jsonl"
typeset tools_command="$ROOT/share/commands/compact_tools/run"
head -n 1 "$compact_source" >"$tools_source"
jq -cn '
  {type:"hook_result",lifecycle:"session_start",id:"1",model_text:"Startup"},
  {type:"user",content:[{type:"text",text:"Investigate"}]},
  {type:"assistant",stop:"tool_calls",content:[
    {type:"tool_call",id:"old_text",name:"shell",input:{command:"false"}},
    {type:"tool_call",id:"old_image",name:"read_file",input:{file_path:"old.png"}}]},
  {type:"tool_result",id:"old_text",name:"shell",input:{command:"false"},exit_code:1,
    model_text:"old diagnostic",user_text:"old displayed diagnostic",user_preview_lines:3},
  {type:"state_update",name:"example/state",value:"old"},
  {type:"tool_result",id:"old_image",name:"read_file",input:{file_path:"old.png"},exit_code:0,
    model_content:[{type:"text",text:"old image"},{type:"image",url:"data:image/png;base64,iVBORw0KGgo="}]},
  {type:"assistant",stop:"end",content:[{type:"text",text:"Investigated"}],usage:{input_tokens:100000,output_tokens:1}},
  {type:"hook_result",lifecycle:"user_prompt_submit",id:"2",model_text:"Retained notice"},
  {type:"user",content:[{type:"text",text:([range(90000) | "x"] | join(""))}]},
  {type:"state_update",name:"example/state",value:null},
  {type:"assistant",stop:"tool_calls",content:[
    {type:"tool_call",id:"recent_image",name:"read_file",input:{file_path:"new.png"}}]},
  {type:"tool_result",id:"recent_image",name:"read_file",input:{file_path:"new.png"},exit_code:0,
    model_content:[{type:"text",text:"new image"},{type:"image",url:"data:image/png;base64,iVBORw0KGgo="}]},
  {type:"assistant",stop:"end",content:[{type:"text",text:"Finished"}],usage:{input_tokens:100000,output_tokens:1}}
' >>"$tools_source"
assert_canonical_session "$tools_source"
typeset tools_before=$(shasum <"$tools_source") tools_request="$tmp/tools-request"
SF_TEST_COMPACT_FAIL=1 SF_TEST_PROVIDER_REQUEST="$tools_request" \
  SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$tools_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$tools_command" \
  3>"$compact_control" 2>"$compact_display" </dev/null || fail 'tool compaction failed'
[[ ! -e $tools_request ]] || fail 'tool compaction requested inference'
assert_equal "$tools_before" "$(shasum <"$tools_source")"
actions | jq -e --arg command "$compact_shellfish" --arg child "$tools_child" '
  . == {action:"handoff",argv:[$command,"--session",$child]}
' >/dev/null || fail 'tool compaction did not hand off to its child'
assert_canonical_session "$tools_child"
assert_mode 600 "$tools_child"
jq -e -s --slurpfile original "$tools_source" '
  [ .[] | select(.type == "tool_result" and (.id | startswith("old_"))) ] as $old |
  ($old | length) == 2 and
  all($old[]; .model_text == "[Results omitted]" and
    .user_text == .model_text and (has("model_content") | not) and
    (has("user_preview_lines") | not)) and
  [.[] | select(.type == "tool_result") | [.id,.name,.input,.exit_code]] ==
    [$original[] | select(.type == "tool_result") | [.id,.name,.input,.exit_code]] and
  [.[] | select(.type == "state_update")] ==
    [$original[] | select(.type == "state_update")] and
  [.[8:][] | del(.usage)] == [$original[8:][] | del(.usage)] and
  .[1] == $original[1] and
  all(.[] | select(.type == "assistant"); has("usage") | not)
' "$tools_child" >/dev/null || fail 'tool compaction changed protected content or state'

# Already-cleared results and sessions without older results are no-ops.
for unchanged in "$tools_child" "$tmp/single.jsonl"; do
  SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$unchanged" \
    SHELLFISH_TURN_STATE="$tmp" zsh -f "$tools_command" \
    3>"$compact_control" 2>"$compact_display" </dev/null || fail 'tool compaction no-op failed'
  [[ -z $(actions) ]] || fail 'tool compaction created an unchanged child'
done

# Exercise command routing, request projection, handoff, and continuation together.
typeset integration_source="$tmp/integration.jsonl" integration_child
typeset integration_stream="$tmp/integration.stream" integration_provider="$tmp/provider"
mkdir -p "$integration_provider" "$tmp/http-bin"
cat >"$integration_provider/run" <<'ZSH'
#!/usr/bin/env zsh
setopt pipe_fail
tee "$SF_TEST_PROVIDER_REQUEST" | "$SF_TEST_TRANSLATOR"
ZSH
cat >"$tmp/http-bin/curl" <<'ZSH'
#!/usr/bin/env zsh
while (( $# )); do
  if [[ $1 == --data-binary ]]; then cp "${2#@}" "$SF_TEST_BODY"; shift; fi
  shift
done
print -r -- '{"choices":[{"message":{"content":"Continuation handoff"},"finish_reason":"stop"}]}'
print -n -u2 -- 200
ZSH
chmod +x "$integration_provider/run" "$tmp/http-bin/curl"
typeset -gx SF_TEST_TRANSLATOR="$ROOT/share/providers/openai_chat/run"
typeset -gx SF_TEST_BODY="$tmp/summary-body.json"
for command in compact compact_tools; do
  jq -c --arg provider "$integration_provider" --arg share "$ROOT/share" '
    if .type == "session" then
      .model.provider=$provider |
      .profile.commands=[$share + "/commands/compact", $share + "/commands/compact_tools"]
    else . end
  ' "$tools_source" >"$integration_source"
  if [[ $command == compact ]]; then
    cp "$integration_source" "$tmp/baseline.jsonl"
    PATH="$tmp/http-bin:$PATH" SF_TEST_PROVIDER_REQUEST="$tmp/normal-request.json" \
      SF_TEST_BODY="$tmp/normal-body.json" \
      sf_test_run Continue "$tmp/baseline.jsonl" >"$integration_stream"
  fi
  rm -f "$compact_request"
  typeset prompt="/$command"
  [[ $command != compact ]] || prompt+=' Preserve E42 exactly'
  PATH="$tmp/http-bin:$PATH" sf_test_run "$prompt" "$integration_source" >"$integration_stream"
  integration_child=$(jq -r 'select(.type == "_handoff") | .argv[2]' "$integration_stream")
  [[ -n $integration_child ]] || fail "$command did not hand off through the public command"
  assert_canonical_session "$integration_child"
  if [[ $command == compact ]]; then
    jq -e --slurpfile normal "$tmp/normal-request.json" '
      del(.messages) == ($normal[0] | del(.messages)) and
      .messages[:-1] == $normal[0].messages[:-1] and
      (.messages[-1].content[0].text | contains("Preserve E42 exactly"))
    ' "$compact_request" >/dev/null || fail 'summary changed the normalized request prefix'
    jq -e --slurpfile normal "$tmp/normal-body.json" '
      del(.messages) == ($normal[0] | del(.messages)) and
      .messages[:-1] == $normal[0].messages[:-1] and
      (.messages[-1].content | contains("Preserve E42 exactly"))
    ' "$SF_TEST_BODY" >/dev/null || fail 'summary changed the provider-visible request prefix'
  else
    [[ ! -e $compact_request ]] || fail 'public tool compaction requested inference'
  fi
  PATH="$tmp/http-bin:$PATH" sf_test_run 'Continue' "$integration_child" >"$integration_stream"
  assert_canonical_session "$integration_child" end
done
