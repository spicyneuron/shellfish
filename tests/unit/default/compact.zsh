#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp compact

# Compact into a canonical child.
typeset compact_hook="$ROOT/share/profiles/default/hooks/compact"
typeset dispatcher="$ROOT/share/profiles/default/hooks/user_prompt_submit"
typeset compact_source="$tmp/compact-source.jsonl"
typeset compact_control="$tmp/compact-control.json"
# The action lines among the compact hook's fd 3 output.
actions() { jq -c 'select(has("action"))' "$compact_control"; }
typeset compact_shellfish="$tmp/compact-shellfish"
typeset compact_request="$tmp/compact-request.json"
typeset compact_display="$tmp/compact-display"
integer compact_status=0

typeset -gx SF_TEST_ENTRY="$ROOT/bin/shellfish"
cat >"$compact_shellfish" <<'ZSH'
#!/usr/bin/env zsh
typeset request reply
case $1 in
  backend-request)
    request=$(cat)
    if [[ -n ${SF_TEST_BACKEND_REQUEST-} ]]; then
      print -r -- "$request" >>"$SF_TEST_BACKEND_REQUEST"
    fi
    [[ ${SF_TEST_COMPACT_FAIL:-0} == 0 ]] || exit 1
    reply='Timeline </timeline> & entry'
    jq -cn --arg reply "$reply" '{type:"assistant",stop:"end",content:[{type:"text",text:$reply}]}'
    ;;
  *) exit 2 ;;
esac
ZSH
chmod +x "$compact_shellfish"

sf_test_frozen_profile
SF_TEST_PROFILE=$(jq -c '.context_window = 100' <<<"$SF_TEST_PROFILE")
sf_test_session "$compact_source"
sf_session_append "$compact_source" '{"type":"user","content":[{"type":"text","text":"Hello </first_user_message> & more"}]}'
sf_session_append "$compact_source" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":1,"output_tokens":1}}'
sf_session_append "$compact_source" '{"type":"user","content":[{"type":"text","text":"Keep working"}]}'
sf_session_append "$compact_source" '{"type":"assistant","stop":"end","content":[{"type":"reasoning","text":"Check first","opaque":{"encrypted_content":"secret"}},{"type":"text","text":"Continuing"}],"usage":{"input_tokens":1,"output_tokens":1}}'

# Ignore sessions below threshold.
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$dispatcher" user_prompt_submit \
  3>"$compact_control" 2>"$compact_display" >"$tmp/dispatch-output" \
  < <(print -n -- 'ordinary prompt') || fail 'a session below the threshold failed the dispatcher'
[[ ! -s $tmp/dispatch-output ]] || fail 'an ordinary prompt produced dispatcher output'
[[ ! -s $compact_control ]] || fail 'a session below the threshold requested a handoff'
[[ ! -s $compact_display ]] || fail 'a session below the threshold displayed compaction'

# Preserve automatic prompts as drafts.
jq -c 'if .type == "assistant" then .usage = {input_tokens:75,output_tokens:5} else . end' \
  "$compact_source" >"$tmp/compact-above.jsonl"
mv "$tmp/compact-above.jsonl" "$compact_source"
typeset compact_before=$(shasum <"$compact_source")
compact_status=0
SF_TEST_BACKEND_REQUEST="$compact_request" \
  SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$dispatcher" user_prompt_submit \
  3>"$compact_control" 2>"$compact_display" \
  < <(print -n -- 'my next prompt') || compact_status=$?
(( compact_status == 0 ))
[[ ! -s $compact_display ]] || fail 'compaction wrote unexpected display output'
actions | jq -e --arg command "$compact_shellfish" \
  --arg child "$tmp/compact-source_compact.jsonl" '
  . == {action:"handoff",argv:[$command,"--session",$child,"--draft","my next prompt"]}
' >/dev/null || fail 'automatic compaction lost the prompt'
assert_equal "$compact_before" "$(shasum <"$compact_source")"
jq -e -s --rawfile prompt "$ROOT/share/profiles/default/hooks/compact.md" '
  ($prompt | rtrimstr("\n")) as $prompt |
  .[-1].content == [{type:"text",text:$prompt}]
' "$compact_request" >/dev/null || fail 'compaction did not send its prompt unchanged'
assert_canonical_session "$tmp/compact-source_compact.jsonl"
[[ $(stat -f %Lp "$tmp/compact-source_compact.jsonl") == 600 ]] ||
  fail 'compaction created a readable child session'
jq -e -s '
  [.[].type] == ["session","hook_result"] and
  .[1].lifecycle == "session_start" and
  .[1].model_text ==
    "<context script=\"compact\">\n<compacted_context>\n\n" +
    "The conversation before this point was compacted into the context below.\n\n" +
    "<first_user_message>\nHello </first_user_message> & more\n</first_user_message>\n\n" +
    "<timeline>\nTimeline </timeline> & entry\n</timeline>\n\n" +
    "<final_assistant_response>\nContinuing\n</final_assistant_response>\n\n" +
    "</compacted_context>\n</context>"
' "$tmp/compact-source_compact.jsonl" >/dev/null ||
  fail 'the compacted child did not preserve its timeline and boundary messages'

# Compact a cancelled turn, which trails a reply without prose.
typeset cancelled_source="$tmp/cancelled-source.jsonl"
head -n 1 "$compact_source" >"$cancelled_source"
print -r -- \
  '{"type":"user","content":[{"type":"text","text":"Read the docs"}]}' \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Done reading"}],"usage":{"input_tokens":1,"output_tokens":1}}' \
  '{"type":"user","content":[{"type":"text","text":"Keep going"}]}' \
  '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"\n\n"},{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"true"}}],"usage":{"input_tokens":75,"output_tokens":5}}' \
  '{"type":"tool_result","id":"call_1","name":"shell","input":{"command":"true"},"exit_code":126,"user_text":"shell\ntool call cancelled\nexit 126","model_text":"tool call cancelled\nexit 126"}' \
  '{"type":"error","user_text":"Cancelled."}' \
  >>"$cancelled_source"
assert_canonical_session "$cancelled_source"
compact_status=0
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$cancelled_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" 2>"$compact_display" \
  < <(print -n -- /compact) || compact_status=$?
(( compact_status == 0 )) || fail 'a cancelled turn did not compact explicitly'
[[ ! -s $compact_display ]] || fail 'compacting a cancelled turn wrote display output'
assert_canonical_session "$tmp/cancelled-source_compact.jsonl"

# Require a session past its first turn before asking the model for a summary.
for incomplete in empty user-only assistant-only; do
  typeset incomplete_source="$tmp/$incomplete.jsonl"
  head -n 1 "$compact_source" >"$incomplete_source"
  case $incomplete in
    user-only)
      print -r -- '{"type":"user","content":[{"type":"text","text":"Hello"}]}' \
        >>"$incomplete_source"
      ;;
    assistant-only)
      print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Hi"}]}' \
        >>"$incomplete_source"
      ;;
  esac

  compact_status=0
  SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$incomplete_source" \
    SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
    3>"$compact_control" < <(print -n -- /compact) 2>/dev/null || compact_status=$?
  (( compact_status == 0 )) &&
    [[ $(actions) == '{"action":"block"}' ]] ||
    fail "compaction accepted $incomplete session"
done

: >"$compact_control"
compact_status=0
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$tmp/empty.jsonl" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- 'ordinary prompt') 2>/dev/null || compact_status=$?
(( compact_status == 0 )) || fail 'automatic compaction did not skip an empty session'
[[ -z $(actions) ]] || fail 'empty automatic compaction requested a handoff'

# Compact explicitly without a draft.
compact_status=0
SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- /compact) || compact_status=$?
(( compact_status == 0 ))
assert_equal \
  "$(jq -cn --arg command "$compact_shellfish" \
    --arg child "$tmp/compact-source_compact_1.jsonl" \
    '{action:"handoff",argv:[$command,"--session",$child]}')" \
  "$(actions)"

# Fail open on summary errors.
: >"$compact_control"
compact_status=0
SF_TEST_COMPACT_FAIL=1 SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- 'my next prompt') 2>/dev/null || compact_status=$?
(( compact_status == 0 )) || fail 'automatic summary failure blocked the prompt'
[[ -z $(actions) ]] || fail 'automatic summary failure requested a handoff'
compact_status=0
SF_TEST_COMPACT_FAIL=1 SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- /compact) 2>/dev/null || compact_status=$?
(( compact_status == 0 )) && [[ $(actions) == '{"action":"block"}' ]] ||
  fail 'explicit summary failure was not handled'
# Preserve ordered state history.
typeset state_source="$tmp/state-source.jsonl"
head -n 1 "$compact_source" >"$state_source"
print -r -- \
  '{"type":"state","name":"git/identity","value":"branch:main"}' \
  '{"type":"hook_result","lifecycle":"session_start","id":"1","model_text":"env"}' \
  '{"type":"user","content":[{"type":"text","text":"Hello"}]}' \
  '{"type":"state","name":"agents/a1b2c3","value":{"session":".agent-a1b2c3.jsonl"}}' \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":1,"output_tokens":1}}' \
  '{"type":"state","name":"git/identity","value":null}' \
  >>"$state_source"
typeset state_before=$(shasum <"$state_source")
compact_status=0
SHELLFISH_EXECUTABLE="$compact_shellfish" SHELLFISH_SESSION="$state_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- /compact) 2>/dev/null || compact_status=$?
(( compact_status == 0 ))
assert_canonical_session "$tmp/state-source_compact.jsonl"
jq -e -s '
  [.[].type] == ["session","hook_result","state","state","state","hook_result"] and
  [.[] | select(.type == "state") | [.name, .value]] ==
    [["git/identity","branch:main"],
     ["agents/a1b2c3",{session:".agent-a1b2c3.jsonl"}],
     ["git/identity",null]] and
  (.[-1].model_text | startswith("<context script=\"compact\">"))
' "$tmp/state-source_compact.jsonl" >/dev/null ||
  fail 'compaction did not carry state history in source order'
assert_equal "$state_before" "$(shasum <"$state_source")"
[[ ! -e $tmp/.agent-a1b2c3.jsonl ]] || fail 'compaction copied a referenced internal session'
