#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-command
sf_test_config
mkdir -p "$tmp/home" "$SF_TEST_CONFIG/profiles/default/system"
print -r -- 'initial system' >"$SF_TEST_CONFIG/profiles/default/system/source.md"
export HOME="${tmp:A}/home"

sf_test_profile default "{
  \"backend\": {\"adapter\": \"$ROOT/tests/fixtures/backend\"},
  \"system\": [\"source.md\"],
  \"request\": {\"model\": \"test-model\"},
  \"tools\": [], \"sandbox\": true,
  \"max_requests_per_turn\": 8, \"max_tool_calls_per_request\": 16,
  \"max_capture_bytes\": 65536
}"
export XDG_STATE_HOME="$tmp/state"
typeset entry="$ROOT/bin/shellfish"
typeset output

# Plain mode prints only the answer.
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run 'plain answer') || \
  fail 'plain run failed'
assert_equal 'plain answer' "$output" 'plain run prints only the answer'

# Multi-request turns print only the final assistant message.
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run 'use a tool') || \
  fail 'plain tool run failed'
assert_equal 'Tool complete.' "$output" 'plain run included an intermediate assistant message'

# JSON mode returns a flattened final result, not a protocol record or turn stream.
typeset json_session="$tmp/json.jsonl"
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --json \
  --session-out "$json_session" 'use a tool') || fail 'JSON run failed'
print -r -- "$output" | jq -e '
  keys == ["message","stop","usage"] and
  .message == "Tool complete." and .stop == "end" and
  (.usage | type == "object")
' >/dev/null || fail 'JSON run returned the wrong structure'
jq -es '[.[] | select(.type == "assistant")] | length == 2' "$json_session" >/dev/null ||
  fail 'JSON test did not exercise an intermediate assistant message'

# Standard input supplies the prompt.
output=$(print -rn -- 'piped answer' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run) || \
  fail 'piped run failed'
assert_equal 'piped answer' "$output" 'run accepts standard input'

# A message argument does not wait for an inherited pipe to close.
integer pipe_started=$SECONDS
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run 'plain answer' \
  < <(sleep 5)) || fail 'run with an open pipe failed'
assert_equal 'plain answer' "$output" 'run ignores an unread pipe'
(( SECONDS - pipe_started < 3 )) || fail 'run waited for an inherited pipe to close'

# Positional prompt words are joined.
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run \
  several prompt words) || fail 'multi-argument run failed'
assert_equal 'several prompt words' "$output" 'run joins positional prompt words'

# Create options preserve their values.
typeset forwarded_session="$tmp/forwarded.jsonl"
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --session-out "$forwarded_session" \
  --model forwarded-model --system 'forwarded system' \
  'plain answer') || fail 'forwarded run failed'
assert_equal 'plain answer' "$output" 'run keeps the prompt after a forwarded value'
head -n 1 "$forwarded_session" | jq -e '
  .runtime.request.model == "forwarded-model" and
  (.runtime.system | length) == 1
' \
  >/dev/null || fail 'a forwarded option value did not reach the new session'
jq -e 'select(.type == "system" and .content == "forwarded system")' \
  "$forwarded_session" >/dev/null || fail 'run did not create the overridden system record'

# Session reuse copies only runtime settings.
typeset copied_session="$tmp/copied.jsonl"
cp "$forwarded_session" "$tmp/source-before"
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run \
  --session-from "$forwarded_session" --session-out "$copied_session" \
  'copied answer') || fail 'run from a session failed'
assert_equal 'copied answer' "$output"
cmp -s "$forwarded_session" "$tmp/source-before" || fail 'run modified its source'
jq -es --slurpfile source "$forwarded_session" '
  .[0].runtime == $source[0].runtime and
  .[1] == {type:"system",content:"initial system"} and
  [.[] | select(.type == "user") | .content[0].text] == ["copied answer"]
' "$copied_session" >/dev/null || fail 'run did not reuse the stored runtime'

# Session source options are exclusive.
integer conflict_status=0
zsh -f "$entry" run --session "$forwarded_session" \
  --session-from "$forwarded_session" ignored >/dev/null 2>&1 || conflict_status=$?
(( conflict_status == 2 )) || fail 'run accepted session with session-from'

conflict_status=0
output=$(zsh -f "$entry" run --session "$forwarded_session" \
  -s "$forwarded_session" ignored 2>&1) || conflict_status=$?
[[ $output == *'--session may only be specified once'* && $conflict_status == 2 ]] ||
  fail 'run did not recognize -s as a repeated session'

# JSONL streams only new turn events.
typeset jsonl stream_session="$tmp/stream.jsonl"
zsh -f "$entry" run --session-create --session-out "$stream_session" >/dev/null ||
  fail 'stream session create failed'
typeset -i prefix=$(jq -es 'length' "$stream_session")
jsonl=$(print -r -- \
  '{"type":"user","content":[{"type":"text","text":"stream answer"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --jsonl \
    --session "$stream_session") || fail 'JSONL run failed'
print -r -- "$jsonl" | jq -eRn -L "$ROOT" '
  include "lib/session";
  [inputs | fromjson] as $events |
  ($events | any(.type == "session") | not) and
  ($events | any(.type == "_assistant_message_delta")) and
  ($events | any(.type == "_turn_usage")) and
  ($events | any(.type == "user")) and
  ($events | any(.type == "assistant" and (.usage | token_usage)))
' >/dev/null || fail 'JSONL run produced the wrong stream'

print -r -- "$jsonl" | jq -c 'select(.type | startswith("_") | not)' \
  >"$tmp/stream-durable"
jq -c . "$stream_session" | tail -n +$(( prefix + 1 )) >"$tmp/session-durable"
cmp -s "$tmp/stream-durable" "$tmp/session-durable" ||
  fail 'JSONL durable events differ from the appended session records'

# Context discovery replaces the complete frozen runtime before inference.
typeset context_backend="$tmp/context-backend"
typeset context_session="$tmp/context.jsonl" context_stream="$tmp/context.stream"
mkdir "$context_backend"
cp "$ROOT/tests/fixtures/backend/manifest.json" "$context_backend/manifest.json"
cp "$ROOT/tests/fixtures/backend/run" "$context_backend/run"
cat >"$context_backend/context_window" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- '{"context_window":4321}'
ZSH
chmod +x "$context_backend/context_window"
sf_test_profile context \
  "{\"extend\": [\"default\"], \"backend\": {\"adapter\": \"$context_backend\"}}"
print -r -- '{"type":"user","content":[{"type":"text","text":"context"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --jsonl -p context \
    --session-out "$context_session" >"$context_stream" ||
  fail 'context discovery run failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(.type) | index("_session_update")) as $update |
  ($events | map(.type) | index("_assistant_start")) as $start |
  $update < $start and $events[$update].runtime.context_window == 4321
' <"$context_stream" >/dev/null || fail 'context discovery emitted the wrong order'
head -n 1 "$context_session" | jq -e \
  '.runtime.context_window == 4321' >/dev/null ||
  fail 'context discovery did not freeze the complete updated runtime'
cat >"$context_backend/context_window" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
exit 7
ZSH
context_session="$tmp/context-unavailable.jsonl"
print -r -- '{"type":"user","content":[{"type":"text","text":"fallback"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --jsonl -p context \
    --session-out "$context_session" >/dev/null ||
  fail 'unavailable context discovery blocked inference'
head -n 1 "$context_session" | jq -e \
  '.runtime.context_window == null' >/dev/null ||
  fail 'unavailable context discovery did not freeze null'

# JSONL emits command handoffs.
typeset handoff_script="$tmp/handoff"
mkdir "$handoff_script"
cat >"$handoff_script/run" <<'ZSH'
#!/usr/bin/env zsh
(( $# == 0 )) || exit 1
print -rn -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
exit 11
ZSH
chmod +x "$handoff_script/run"
typeset handoff_output="$tmp/handoff.jsonl"
sf_test_profile handoff \
  "{\"extend\": [\"default\"], \"hooks\": {\"user_prompt_submit\": [\"$handoff_script\"]}}"
print -r -- \
  '{"type":"user","content":[{"type":"text","text":"handoff"}]}' |
  zsh -f "$entry" run --jsonl -p handoff \
  >"$handoff_output" || fail 'JSONL run rejected a handoff'
jq -eRn '
  [inputs | fromjson] as $events |
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  ($events | any(.type == "user") | not)
' <"$handoff_output" >/dev/null || fail 'JSONL run discarded the handoff'

# Invalid session paths fail cleanly.
typeset invalid_path="$tmp/invalid-path" invalid_path_output="$tmp/invalid-path.out"
ln -s "$SF_TEST_CONFIG/profiles/default/profile.jsonc" "$invalid_path"
integer invalid_path_status=0
print -r -- \
  '{"type":"user","content":[{"type":"text","text":"ignored"}]}' |
  zsh -f "$entry" run --jsonl --session "$invalid_path" \
  >"$invalid_path_output" 2>"$tmp/invalid-path.stderr" || invalid_path_status=$?
(( invalid_path_status == 1 ))
[[ ! -s $invalid_path_output ]]
[[ $(<"$tmp/invalid-path.stderr") == *"invalid session path: $invalid_path"* ]] ||
  fail 'JSONL prepare failure omitted stderr diagnostic'

# Invalid input combinations are rejected.
integer exit_code=0
zsh -f "$entry" run --json --jsonl >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'run accepted --json with --jsonl'
exit_code=0
print -n piped | zsh -f "$entry" run argument >/dev/null 2>&1 || \
  exit_code=$?
(( exit_code == 2 )) || fail 'run accepted prompt argument and stdin together'
exit_code=0
print -n '{}' | zsh -f "$entry" run --jsonl >/dev/null 2>&1 || \
  exit_code=$?
(( exit_code == 2 )) || fail 'run accepted noncanonical JSON input'
exit_code=0
zsh -f "$entry" run --session-create --session "$stream_session" \
  >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'session creation accepted an existing session'
exit_code=0
zsh -f "$entry" run --session-create prompt \
  >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'session creation accepted a prompt argument'
exit_code=0
print -r -- prompt | zsh -f "$entry" run --session-create \
  >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'session creation accepted a prompt on stdin'

print -r -- 'ok'
