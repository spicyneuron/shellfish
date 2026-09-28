#!/usr/bin/env zsh
source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-create-hook-contract
sf_test_config
export XDG_STATE_HOME="$tmp/state"
typeset entry="$ROOT/bin/shellfish" hook="$SF_TEST_CONFIG/hooks/project/instructions"
typeset project="$tmp/project" session="$tmp/session.jsonl" stream="$tmp/stream"
mkdir -p "$hook" "$project"
cp "$ROOT/share/hooks/project/instructions/"{manifest.json,run} "$hook/"
print -r -- 'Follow this project rule.' >"$project/AGENTS.md"
sf_test_profile default "{
  \"backend\":{\"adapter\":\"$ROOT/tests/fixtures/backend\"},
  \"request\":{\"model\":\"test\"},
  \"tools\":[],\"sandbox\":false,
  \"hooks\":{\"session_start\":[\"project/instructions\"]},
  \"max_capture_bytes\":1024
}"
(cd "$project" && zsh -f "$entry" run --jsonl --session-create --session-out "$session") \
  >"$stream" || fail 'manifested session_start hook failed'
jq -eRn --arg session "$session" --arg hook "${hook:A}" '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","_draft","hook_result"] and
  $events[0] == {type:"_session_load",path:$session} and
  $events[1].profile.hooks.session_start == [$hook] and
  ($events[2] | .lifecycle == "session_start" and
    .user_text == "Loading AGENTS.md…") and
  ($events[3] | .lifecycle == "session_start" and
    .user_text == "Project instructions (AGENTS.md):\nFollow this project rule.\n" and
    (.model_text | contains("<context script=\"project/instructions\">")))
' <"$stream" >/dev/null || fail 'hook draft, name, or settlement was wrong'
assert_canonical_session "$session"
create() {
  (cd "$project" && zsh -f "$entry" run --jsonl --session-create --session-out "$1") \
    >"$stream"
}
# Manifest-only progress and literal Done text need no fd3 or captured output.
print -r -- '{"user_text":"Running ${name}","user_text_done":"Finished",
  "user_preview_lines":"full"}' >"$hook/manifest.json"
print -r -- '#!/usr/bin/env zsh' >"$hook/run"
session="$tmp/literal.jsonl"
create "$session" || fail 'manifest-only hook failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","_draft","hook_result"] and
  $events[2].user_text == "Running project/instructions" and
  $events[3].user_text == "Finished" and
  all($events[2:4][]; .user_preview_lines == "full") and
  ($events[3] | has("model_text") | not)
' <"$stream" >/dev/null || fail 'manifest progress, literal Done, or preview was lost'
sf_test_profile absolute "{\"extend\":[\"default\"],
  \"hooks\":{\"session_start\":[\"$hook\"]}}"
(cd "$project" && zsh -f "$entry" run --jsonl --session-create \
  --session-out "$tmp/absolute.jsonl" -p absolute) >"$stream" || fail 'absolute hook failed'
jq -eRn '
  [inputs | fromjson | select(.type == "_draft")][0].user_text == "Running project/instructions"
' <"$stream" >/dev/null || fail 'absolute hook under the configured root lost its relative name'
print -r -- '{"user_text":"Working","user_text_done":""}' >"$hook/manifest.json"
session="$tmp/manifest-silent.jsonl"
create "$session" || fail 'manifest-only silent hook failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","_draft","_draft"] and
  $events[2].user_text == "Working" and $events[3].user_text == ""
' <"$stream" >/dev/null || fail 'manifest-only draft was not cleared'
jq -e -s 'map(.type) == ["session"]' "$session" >/dev/null ||
  fail 'manifest-only draft became durable'
# State arrives before the result, and captured `${...}` text is never expanded.
print -r -- '{"user_text":"Running ${name}",
  "user_text_done":"${data.tag}: ${output.stdout}",
  "model_text":"${output.stdout}"}' >"$hook/manifest.json"
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
print -r -u3 -- '{"state":[{"name":"startup/ready","value":true}],"data":{"tag":"Done"}}'
print -rn -- 'literal ${input}'
ZSH
session="$tmp/state.jsonl"
create "$session" || fail 'manifested state hook failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","_draft","state","_draft","hook_result"] and
  $events[2].user_text == "Running project/instructions" and
  $events[3] == {type:"state",name:"startup/ready",value:true} and
  $events[4].user_text == "Running project/instructions" and
  $events[5].user_text == "Done: literal ${input}" and
  $events[5].model_text == "literal ${input}"
' <"$stream" >/dev/null || fail 'state, name, or literal output was wrong'
# Oversized hook output settles from bounded tails on both capture channels.
print -r -- '{"user_text_done":"${output.stdout}|${output.stderr}",
  "model_text":"${output.stdout}${output.stderr}"}' >"$hook/manifest.json"
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- 'head'${(l:1200::o:)}'stdout-tail'
print -rn -u2 -- 'head'${(l:1200::e:)}'stderr-tail'
ZSH
session="$tmp/bounded.jsonl"
create "$session" || fail 'bounded manifested hook failed'
jq -eRn '
  [inputs | fromjson | select(.type == "hook_result")][0] as $result |
  ($result.user_text | contains("stdout-tail") and contains("stderr-tail") and
    (contains("head") | not)) and
  ([$result.user_text | scan("\\[output truncated\\]")] | length) == 2 and
  ($result.model_text | contains("stdout-tail") and contains("stderr-tail"))
' <"$stream" >/dev/null || fail 'hook capture did not render bounded tails'
# An empty settled template clears a transient draft and creates no record.
print -r -- '{}' >"$hook/manifest.json"
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
print -r -u3 -- '{"user_text":"Working","user_text_done":"","model_text":""}'
print -rn -- 'unrendered output'
ZSH
session="$tmp/silent.jsonl"
create "$session" || fail 'silent manifested hook failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","_draft","_draft"] and
  $events[2].user_text == "Working" and
  $events[3].user_text == ""
' <"$stream" >/dev/null || fail 'empty Done did not clear its draft'
# Nonzero exit keeps accepted state, discards the proposed action, and fails.
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
print -r -u3 -- '{"state":[{"name":"startup/failed","value":true}],"user_text":"Working"}'
print -rn -u2 -- 'hook broke'
exit 7
ZSH
session="$tmp/failed.jsonl"
integer result=0
create "$session" 2>"$tmp/failed.stderr" || result=$?
(( result == 1 )) || fail 'nonzero manifested hook did not fail creation'
[[ $(<"$tmp/failed.stderr") == *'session_start hook failed with status 7'*'hook broke'* ]] ||
  fail 'nonzero hook lost its diagnostic'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","state","_draft","_draft"] and
  $events[2] == {type:"state",name:"startup/failed",value:true} and
  $events[-1].user_text == ""
' <"$stream" >/dev/null || fail 'failed hook lost state or live draft clearing'
assert_canonical_session "$session"
# Removed fd3 fields fail instead of reviving section or preview behavior.
typeset field
for field in finalize user_preview_lines; do
  print -r -- '#!/usr/bin/env zsh' >"$hook/run"
  print -r -- "print -r -u3 -- '{\"$field\":true}'" >>"$hook/run"
  session="$tmp/invalid-$field.jsonl"
  result=0
  create "$session" 2>"$tmp/invalid.stderr" || result=$?
  (( result == 1 )) || fail "removed fd3 $field was accepted"
  [[ $(<"$tmp/invalid.stderr") == *'returned invalid control'* ]] ||
    fail "removed fd3 $field lost its diagnostic"
  jq -e -s 'map(.type) == ["session"]' "$session" >/dev/null ||
    fail "removed fd3 $field produced a result"
done
# A file is not a hook component, even when executable.
typeset legacy="$tmp/legacy-hook"
print -r -- '#!/usr/bin/env zsh' >"$legacy"
chmod +x "$legacy"
sf_test_profile legacy "{\"extend\":[\"default\"],
  \"hooks\":{\"session_start\":[\"$legacy\"]}}"
result=0
(cd "$project" && zsh -f "$entry" run --session-create --session-out "$tmp/legacy.jsonl" \
  -p legacy) >"$stream" 2>"$tmp/legacy.stderr" || result=$?
(( result == 1 )) || fail 'file hook reference was accepted'
[[ $(<"$tmp/legacy.stderr") == *'invalid hooks reference'* ]] ||
  fail 'file hook rejection lost its diagnostic'
# External absolute references keep their absolute name, even under /hooks/.
typeset external="$tmp/external/hooks/probe"
mkdir -p "$external"
print -r -- '{"user_text_done":"${name}"}' >"$external/manifest.json"
print -r -- '#!/usr/bin/env zsh' >"$external/run"
chmod +x "$external/run"
sf_test_profile external "{\"extend\":[\"default\"],
  \"hooks\":{\"session_start\":[\"$external\"]}}"
session="$tmp/external.jsonl"
(cd "$project" && zsh -f "$entry" run --jsonl --session-create --session-out "$session" \
  -p external) >"$stream" || fail 'external hook failed'
jq -eRn --arg name "${external:A}" '
  [inputs | fromjson | select(.type == "hook_result")][0].user_text == $name
' <"$stream" >/dev/null || fail 'absolute external hook name was rewritten'

# Reconstruct model context after removing the live manifest.
rm "$hook/manifest.json"
session="$tmp/session.jsonl"
jq -e -s -L "$ROOT" '
  include "lib/profile";
  include "lib/session";
  .[1:] | session_messages[-1].content[0].text |
  contains("<context script=\"project/instructions\">") and
  contains("Follow this project rule.")
' "$session" >/dev/null || fail 'replay needed the live manifest'
result=0
(cd "$project" && zsh -f "$entry" run --session-create --session-out "$tmp/missing.jsonl") \
  >"$stream" 2>"$tmp/missing.stderr" || result=$?
(( result == 1 )) || fail 'hook without a manifest was accepted'
[[ $(<"$tmp/missing.stderr") == *'cannot read component manifest'* ]] ||
  fail 'missing hook manifest lost its diagnostic'
typeset invalid
for invalid in field template; do
  if [[ $invalid == field ]]; then
    print -r -- '{"description":"not a hook field"}' >"$hook/manifest.json"
  else
    print -r -- '{"user_text_done":"${input.undeclared}"}' >"$hook/manifest.json"
  fi
  result=0
  (cd "$project" && zsh -f "$entry" run --session-create \
    --session-out "$tmp/invalid-manifest-$invalid.jsonl") \
    >"$stream" 2>"$tmp/invalid-manifest.stderr" || result=$?
  (( result == 1 )) || fail "invalid hook manifest $invalid was accepted"
  [[ $(<"$tmp/invalid-manifest.stderr") == *'invalid hook manifest'* ]] ||
    fail "invalid hook manifest $invalid lost its diagnostic"
done
print -r -- ok
