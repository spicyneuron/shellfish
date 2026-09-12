#!/usr/bin/env zsh

source "${0:A:h:h}/_hooks.zsh"

# Compact into a canonical child.
typeset compact_hook="$ROOT/share/default/hooks/user_prompt_submit/compact/run"
typeset compact_check="$ROOT/share/default/hooks/user_prompt_submit/compact/check"
typeset compact_source="$tmp/compact-source.jsonl"
typeset compact_control="$tmp/compact-control.json"
typeset compact_shellfish="$tmp/compact-shellfish"
typeset compact_request="$tmp/compact-request.json"
typeset compact_display="$tmp/compact-display"
integer compact_status=0

sf_test_runtime
SF_TEST_RUNTIME=$(jq -c '.profile.context_window = 100' <<<"$SF_TEST_RUNTIME")
sf_test_session "$compact_source"
sf_session_begin_turn "$compact_source"
sf_session_append "$compact_source" '{"type":"user","content":[{"type":"text","text":"Hello"}]}'
sf_session_append "$compact_source" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":1,"output_tokens":1}}'
sf_session_reset

# Ignore sessions below threshold.
: >"$compact_control"
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_check" user_prompt_submit \
  2>"$compact_display" \
  < <(print -n -- 'ordinary prompt') || compact_status=$?
(( compact_status == 1 )) || fail 'a session below the threshold selected compaction'
[[ ! -s $compact_control ]] || fail 'a session below the threshold requested a handoff'
[[ ! -s $compact_display ]] || fail 'a session below the threshold displayed compaction'

# Preserve automatic prompts as drafts.
jq -c 'if .type == "assistant" then .usage = {input_tokens:75,output_tokens:5} else . end' \
  "$compact_source" >"$tmp/compact-above.jsonl"
mv "$tmp/compact-above.jsonl" "$compact_source"
typeset compact_before=$(shasum <"$compact_source")
SHELLFISH_SESSION="$compact_source" zsh -f "$compact_check" user_prompt_submit \
  < <(print -n -- 'my next prompt') || fail 'threshold did not select compaction'
SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_REQUEST="$compact_request" \
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" 2>"$compact_display" \
  < <(print -n -- 'my next prompt') || compact_status=$?
(( compact_status == 11 ))
[[ ! -s $compact_display ]] || fail 'compaction wrote unexpected display output'
jq -e --arg command "$ROOT/bin/shellfish" \
  --arg child "$tmp/compact-source_compact.jsonl" '
  . == {action:"handoff",argv:[$command,"--session",$child,"--draft","my next prompt"]}
' "$compact_control" >/dev/null || fail 'automatic compaction lost the prompt'
assert_equal "$compact_before" "$(shasum <"$compact_source")"
jq -e '.tools == []' "$compact_request" >/dev/null || fail 'compaction exposed tools'
jq -e --rawfile prompt "$ROOT/share/default/hooks/user_prompt_submit/compact/compact.md" '
  ($prompt | rtrimstr("\n")) as $prompt |
  ("<compaction_request>\n\n" + $prompt + "\n\n## Summary budget\n\n") as $prefix |
  "\n\n</compaction_request>" as $suffix |
  .messages[-1].content as $content |
  ($content | length) == 1 and $content[0].type == "text" and
  ($content[0].text |
    startswith($prefix) and
    endswith($suffix) and
    (ltrimstr($prefix) | rtrimstr($suffix) |
      test("(^|[^0-9])10([^0-9]|$)")))
' "$compact_request" >/dev/null || fail 'compaction did not use its structured prompt and budget'
assert_canonical_session "$tmp/compact-source_compact.jsonl"
jq -e -s '
  [.[].type] == ["session","hook_result"] and
  .[1].hook == "compact" and .[1].script == "compact" and
  (.[1].model_context | length) > 0
' "$tmp/compact-source_compact.jsonl" >/dev/null ||
  fail 'the compacted child is not a lone summary context'

typeset -gx SF_TEST_ENTRY="$ROOT/bin/shellfish"
cat >"$compact_shellfish" <<'ZSH'
#!/usr/bin/env zsh
case $1 in
  build-request) cat ;;
  install-session) exec "$SF_TEST_ENTRY" "$@" ;;
  send-request)
    cat >/dev/null
    [[ ${SF_TEST_COMPACT_FAIL:-0} == 0 ]] || exit 1
    print -r -- '{"content":[{"type":"text","text":"Summary"}]}'
    ;;
  *) exit 2 ;;
esac
ZSH
chmod +x "$compact_shellfish"

# Compact explicitly without a draft.
compact_status=0
SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- /compact) || compact_status=$?
(( compact_status == 11 ))
assert_equal \
  "$(jq -cn --arg command "$compact_shellfish" \
    --arg child "$tmp/compact-source_compact_1.jsonl" \
    '{action:"handoff",argv:[$command,"--session",$child]}')" \
  "$(<"$compact_control")"

# Fail open on summary errors.
: >"$compact_control"
compact_status=0
SF_TEST_COMPACT_FAIL=1 SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- 'my next prompt') 2>/dev/null || compact_status=$?
(( compact_status == 0 )) || fail 'automatic summary failure blocked the prompt'
[[ ! -s $compact_control ]] || fail 'automatic summary failure requested a handoff'
compact_status=0
SF_TEST_COMPACT_FAIL=1 SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" < <(print -n -- /compact) 2>/dev/null || compact_status=$?
(( compact_status == 10 )) || fail 'explicit summary failure was not handled'
[[ ! -s $compact_control ]] || fail 'explicit summary failure requested a handoff'

# Preserve ordered state history.
typeset state_source="$tmp/state-source.jsonl"
head -n 1 "$compact_source" >"$state_source"
print -r -- \
  '{"type":"state","name":"git/identity","value":"branch:main"}' \
  '{"type":"hook_result","hook":"session_start","script":"project_environment","model_context":"env"}' \
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
(( compact_status == 11 ))
assert_canonical_session "$tmp/state-source_compact.jsonl"
jq -e -s '
  [.[].type] == ["session","hook_result","state","state","state","hook_result"] and
  [.[] | select(.type == "state") | [.name, .value]] ==
    [["git/identity","branch:main"],
     ["agents/a1b2c3",{session:".agent-a1b2c3.jsonl"}],
     ["git/identity",null]] and
  .[-1].script == "compact"
' "$tmp/state-source_compact.jsonl" >/dev/null ||
  fail 'compaction did not carry state history in source order'
assert_equal "$state_before" "$(shasum <"$state_source")"
[[ ! -e $tmp/.agent-a1b2c3.jsonl ]] || fail 'compaction copied a referenced internal session'
