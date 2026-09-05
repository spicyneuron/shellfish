#!/usr/bin/env zsh

source "${0:A:h:h}/_hooks.zsh"

# Compaction is one hook invocation that composes the read-only request commands,
# publishes a canonical child, and returns an ordinary handoff.
typeset compact_hook="$ROOT/share/default/hooks/user_prompt_submit/compact"
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
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"Hello"}]}'
sf_session_append '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":1,"output_tokens":1}}'
sf_session_reset

# Below the threshold an ordinary prompt is left alone.
: >"$compact_control"
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" 2>"$compact_display" \
  < <(print -n -- 'ordinary prompt') || compact_status=$?
(( compact_status == 0 )) || fail 'a session below the threshold was compacted'
[[ ! -s $compact_control ]] || fail 'a session below the threshold requested a handoff'
[[ ! -s $compact_display ]] || fail 'a session below the threshold displayed compaction'

# At or above it, the submitted prompt is carried back as a draft.
jq -c 'if .role == "assistant" then .usage = {input_tokens:75,output_tokens:5} else . end' \
  "$compact_source" >"$tmp/compact-above.jsonl"
mv "$tmp/compact-above.jsonl" "$compact_source"
typeset compact_before=$(shasum <"$compact_source")
SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_REQUEST="$compact_request" \
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$compact_source" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$compact_hook" user_prompt_submit \
  3>"$compact_control" 2>"$compact_display" \
  < <(print -n -- 'my next prompt') || compact_status=$?
(( compact_status == 11 ))
[[ $(head -n 1 "$compact_display") == 'Compacting conversation…' ]] ||
  fail 'automatic compaction did not display its notice'
jq -e --arg command "$ROOT/bin/shellfish" \
  --arg child "$tmp/compact-source_compact.jsonl" '
  . == {action:"handoff",argv:[$command,"--session",$child,"--draft","my next prompt"]}
' "$compact_control" >/dev/null || fail 'automatic compaction lost the prompt'
assert_equal "$compact_before" "$(shasum <"$compact_source")"
jq -e '.tools == []' "$compact_request" >/dev/null || fail 'compaction exposed tools'
jq -e --rawfile prompt "$ROOT/share/default/hooks/user_prompt_submit/compact.md" '
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
  [.[].type] == ["session","context"] and
  .[1].hook == "compact" and .[1].script == "compact" and
  (.[1].content | length) > 0
' "$tmp/compact-source_compact.jsonl" >/dev/null ||
  fail 'the compacted child is not a lone summary context'

# Remaining cases exercise compaction policy without repeating request command startup.
cat >"$compact_shellfish" <<'ZSH'
#!/usr/bin/env zsh
case $1 in
  build-request) cat ;;
  send-request)
    cat >/dev/null
    [[ ${SF_TEST_COMPACT_FAIL:-0} == 0 ]] || exit 1
    print -r -- '{"content":[{"type":"text","text":"Summary"}]}'
    ;;
  *) exit 2 ;;
esac
ZSH
chmod +x "$compact_shellfish"

# /compact creates a numbered sibling and hands off without a draft.
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

# Summary failure is fail-open for an automatic trigger and handled for an
# explicit command. Neither path requests a handoff or creates a child.
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

# Publication failure is also fail-open and preserves an automatic prompt. The
# source name fits the filesystem component limit while its compact sibling does not.
typeset compact_long="$tmp/${(l:245::a:)}.jsonl"
cp "$compact_source" "$compact_long"
: >"$compact_control"
compact_status=0
SHELLFISH_EXECUTABLE="$compact_shellfish" \
  SHELLFISH_SESSION="$compact_long" SHELLFISH_TURN_STATE="$tmp" \
  zsh -f "$compact_hook" user_prompt_submit 3>"$compact_control" \
  < <(print -n -- 'my next prompt') 2>/dev/null || compact_status=$?
(( compact_status == 0 )) || fail 'publication failure blocked the prompt'
[[ ! -s $compact_control ]] || fail 'publication failure requested a handoff'

# A session with no messages reports rather than compacting.
compact_status=0
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  SHELLFISH_SESSION="$tmp/compact-source_compact.jsonl" SHELLFISH_TURN_STATE="$tmp" \
  zsh -f "$compact_hook" user_prompt_submit 3>"$compact_control" \
  < <(print -n -- /compact) 2>/dev/null || compact_status=$?
(( compact_status == 10 )) || fail '/compact accepted a session without messages'
