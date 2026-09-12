#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-command
mkdir -p "$tmp/home" "$tmp/system"
print -r -- 'initial system' >"$tmp/system/source.md"
export HOME="${tmp:A}/home"
unset XDG_CONFIG_HOME

typeset config="$tmp/shellfish.jsonc"
cat >"$config" <<EOF
{
  "default_profile": "exec",
  "backends": {"fixture": {"adapter": "$ROOT/tests/fixtures/backend"}},
  "harnesses": {
    "machine": {
      "tools": [], "sandbox": true,
      "session_start": [], "user_prompt_submit": [], "permission_request": [],
      "pre_tool_use": [], "post_tool_use": [], "stop": [],
      "max_requests_per_turn": 8, "max_tool_calls_per_request": 16,
      "max_capture_bytes": 65536
    }
  },
  "profiles": {
    "exec": {
      "backend": "fixture", "harness": "machine", "system": ["source.md"],
      "request": {"model": "test-model"}
    }
  }
}
EOF
export XDG_STATE_HOME="$tmp/state"
typeset entry="$ROOT/bin/shellfish"
typeset output

# Turn subprocesses preserve the chat's verbose override, but do not trust
# arbitrary inherited values.
typeset verbose_script="$tmp/verbose-hook" verbose_config="$tmp/verbose-config.json"
mkdir "$verbose_script"
cat >"$verbose_script/run" <<'EOF'
#!/usr/bin/env zsh
print -r -- "${SHELLFISH_VERBOSE-unset}" >"$SF_VERBOSE_MARKER"
exit 10
EOF
chmod +x "$verbose_script/run"
jq --arg script "$verbose_script" '.harnesses.machine.user_prompt_submit=[$script]' \
  "$config" >"$verbose_config"
SF_VERBOSE_MARKER="$tmp/verbose-one" SHELLFISH_VERBOSE=1 \
  zsh -f "$entry" run --config "$verbose_config" test || fail 'verbose run failed'
assert_equal 1 "$(<"$tmp/verbose-one")"
SF_VERBOSE_MARKER="$tmp/verbose-invalid" SHELLFISH_VERBOSE=invalid \
  zsh -f "$entry" run --config "$verbose_config" test || fail 'normalized run failed'
assert_equal 0 "$(<"$tmp/verbose-invalid")"

# Plain mode prints only the final assistant text.
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --config "$config" 'plain answer') || \
  fail 'plain run failed'
assert_equal 'plain answer' "$output" 'plain run prints only the answer'

integer failed_status=0
SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --config "$config" \
  'retry error later' >/dev/null 2>&1 || failed_status=$?
(( failed_status == 1 )) || fail 'recoverable turn failure exited successfully'

output=$(print -rn -- 'piped answer' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --config "$config") || \
  fail 'piped run failed'
assert_equal 'piped answer' "$output" 'run accepts standard input'

output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --config "$config" \
  several prompt words) || fail 'multi-argument run failed'
assert_equal 'several prompt words' "$output" 'run joins positional prompt words'

# An option run does not own reaches shellfish create with its value intact,
# and that value is not mistaken for the prompt that follows it.
typeset forwarded_session="$tmp/forwarded.jsonl"
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --session-out "$forwarded_session" \
  --config "$config" --model forwarded-model --system 'forwarded system' \
  'plain answer') || fail 'forwarded run failed'
assert_equal 'plain answer' "$output" 'run keeps the prompt after a forwarded value'
head -n 1 "$forwarded_session" | jq -e '
  .profile.request.model == "forwarded-model" and
  (.profile.system | length) == 1
' \
  >/dev/null || fail 'a forwarded option value did not reach the new session'
jq -e 'select(.type == "system" and .content == "forwarded system")' \
  "$forwarded_session" >/dev/null || fail 'run did not create the overridden system record'

# Reusing settings creates a separate session without replaying source messages.
typeset copied_session="$tmp/copied.jsonl"
cp "$forwarded_session" "$tmp/source-before"
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run \
  --session-from "$forwarded_session" --session-out "$copied_session" \
  'copied answer') || fail 'run from a session failed'
assert_equal 'copied answer' "$output"
cmp -s "$forwarded_session" "$tmp/source-before" || fail 'run modified its source'
jq -es --slurpfile source "$forwarded_session" '
  .[0].profile == $source[0].profile and
  .[1] == {type:"system",content:"initial system"} and
  [.[] | select(.type == "user") | .content[0].text] == ["copied answer"]
' "$copied_session" >/dev/null || fail 'run did not reuse the stored runtime'

integer conflict_status=0
zsh -f "$entry" run --session "$forwarded_session" \
  --session-from "$forwarded_session" ignored >/dev/null 2>&1 || conflict_status=$?
(( conflict_status == 2 )) || fail 'run accepted session with session-from'

conflict_status=0
output=$(zsh -f "$entry" run --session "$forwarded_session" \
  -s "$forwarded_session" ignored 2>&1) || conflict_status=$?
[[ $output == *'--session may only be specified once'* && $conflict_status == 2 ]] ||
  fail 'run did not recognize -s as a repeated session'

# JSONL exposes the canonical turn stream through EOF and process status. The
# session prefix is created before the turn and is not replayed onto the stream.
typeset jsonl stream_session="$tmp/stream.jsonl"
zsh -f "$entry" create --session-out "$stream_session" --config "$config" >/dev/null ||
  fail 'stream session create failed'
typeset -i prefix=$(jq -es 'length' "$stream_session")
jsonl=$(print -r -- \
  '{"type":"user","content":[{"type":"text","text":"stream answer"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --jsonl --config "$config" \
    --session "$stream_session") || fail 'JSONL run failed'
print -r -- "$jsonl" | jq -eRn -L "$ROOT" '
  include "lib/runtime/schema";
  [inputs | fromjson] as $events |
  ($events | any(.type == "session") | not) and
  ($events | any(.type == "_assistant_message_delta")) and
  ($events | any(.type == "_turn_usage")) and
  ($events | any(.type == "user")) and
  ($events | any(.type == "assistant" and (.usage | token_usage)))
' >/dev/null || fail 'JSONL run produced the wrong stream'

print -r -- "$jsonl" | jq -c -L "$ROOT" '
  include "lib/runtime/schema";
  select(canonical_session_header(1) or canonical_session_record)
' \
  >"$tmp/stream-durable"
jq -c . "$stream_session" | tail -n +$(( prefix + 1 )) >"$tmp/session-durable"
cmp -s "$tmp/stream-durable" "$tmp/session-durable" ||
  fail 'JSONL durable events differ from the appended session records'

# A bounded turn emits an arbitrary command handoff and completes cleanly.
typeset handoff_script="$tmp/handoff"
mkdir "$handoff_script"
cat >"$handoff_script/run" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == user_prompt_submit ]] || exit 1
print -rn -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
exit 11
ZSH
chmod +x "$handoff_script/run"
typeset handoff_config="$tmp/handoff.jsonc" handoff_output="$tmp/handoff.jsonl"
jq --arg script "$handoff_script" '.harnesses.machine.user_prompt_submit=[$script]' \
  "$config" >"$handoff_config"
print -r -- \
  '{"type":"user","content":[{"type":"text","text":"handoff"}]}' |
  zsh -f "$entry" run --jsonl --config "$handoff_config" \
  >"$handoff_output" || fail 'JSONL run rejected a handoff'
jq -eRn '
  [inputs | fromjson] as $events |
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  ($events | any(.type == "user") | not)
' <"$handoff_output" >/dev/null || fail 'JSONL run discarded the handoff'

# Session creation and its session_start failures belong to shellfish create.

typeset invalid_path="$tmp/invalid-path" invalid_path_output="$tmp/invalid-path.out"
ln -s "$config" "$invalid_path"
integer invalid_path_status=0
print -r -- \
  '{"type":"user","content":[{"type":"text","text":"ignored"}]}' |
  zsh -f "$entry" run --jsonl --session "$invalid_path" \
  >"$invalid_path_output" 2>"$tmp/invalid-path.stderr" || invalid_path_status=$?
(( invalid_path_status == 1 ))
[[ ! -s $invalid_path_output ]]
[[ $(<"$tmp/invalid-path.stderr") == *"invalid session path: $invalid_path"* ]] ||
  fail 'JSONL prepare failure omitted stderr diagnostic'

integer exit_code=0
print -n piped | zsh -f "$entry" run --config "$config" argument >/dev/null 2>&1 || \
  exit_code=$?
(( exit_code == 2 )) || fail 'run accepted prompt argument and stdin together'
exit_code=0
print -n '{}' | zsh -f "$entry" run --jsonl --config "$config" >/dev/null 2>&1 || \
  exit_code=$?
(( exit_code == 2 )) || fail 'run accepted noncanonical JSON input'
exit_code=0
zsh -f "$entry" --jsonl >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'chat accepted --jsonl'
exit_code=0
zsh -f "$entry" run --draft draft prompt >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'run accepted --draft'
exit_code=0
zsh -f "$entry" run --verbose --config "$config" hi >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'run accepted --verbose'

print -r -- 'ok'
