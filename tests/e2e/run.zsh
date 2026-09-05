#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
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
      "sandbox_read_paths": ["$tmp/read"],
      "sandbox_write_paths": ["$tmp/write"],
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
mkdir "$tmp/read" "$tmp/write"

# Turn subprocesses preserve the chat's verbose override, but do not trust
# arbitrary inherited values.
typeset verbose_script="$tmp/verbose-hook" verbose_config="$tmp/verbose-config.json"
cat >"$verbose_script" <<'EOF'
#!/usr/bin/env zsh
print -r -- "${SHELLFISH_VERBOSE-unset}" >"$SF_VERBOSE_MARKER"
exit 10
EOF
chmod +x "$verbose_script"
jq --arg script "$verbose_script" '.harnesses.machine.user_prompt_submit=[$script]' \
  "$config" >"$verbose_config"
SF_VERBOSE_MARKER="$tmp/verbose-one" SHELLFISH_VERBOSE=1 \
  zsh -f "$entry" run --config "$verbose_config" test || fail 'verbose run failed'
assert_equal 1 "$(<"$tmp/verbose-one")"
SF_VERBOSE_MARKER="$tmp/verbose-invalid" SHELLFISH_VERBOSE=invalid \
  zsh -f "$entry" run --config "$verbose_config" test || fail 'normalized run failed'
assert_equal 0 "$(<"$tmp/verbose-invalid")"

output=$(zsh -f "$entry" config --config "$config") || fail 'sandbox paths were rejected'
jq -e --arg read "$tmp/read" --arg write "$tmp/write" '
  .harness.sandbox_read_paths == [$read] and
  .harness.sandbox_write_paths == [$write]
' <<<"$output" >/dev/null || fail 'sandbox paths were not frozen in the runtime'

sed 's#"sandbox_read_paths": \["[^\"]*"\]#"sandbox_read_paths": ["relative"]#' \
  "$config" >"$tmp/invalid-path.jsonc"
zsh -f "$entry" config --config "$tmp/invalid-path.jsonc" >/dev/null 2>&1 && \
  fail 'relative sandbox path was accepted'

# Sandbox paths accept files, directories, relative paths, and home-relative paths.
mkdir "$tmp/added"
touch "$tmp/read-file"
output=$(cd "$tmp" && zsh -f "$entry" config --config "$config" \
  --sandbox-read read-file --sandbox-write added) || fail 'sandbox path flags rejected valid paths'
jq -e --arg read "$tmp/read" --arg write "$tmp/write" \
  --arg read_file "${tmp:A}/read-file" --arg write_dir "${tmp:A}/added" '
  .harness.sandbox_read_paths == [$read,$read_file] and
  .harness.sandbox_write_paths == [$write,$write_dir]
' <<<"$output" >/dev/null || fail 'sandbox path flags were not frozen in the runtime'
typeset newline_dir="$tmp/"$'line\nbreak'
mkdir "$newline_dir"
output=$(zsh -f "$entry" config --config "$config" --sandbox-read "$newline_dir") || \
  fail '--sandbox-read rejected a newline-containing path'
jq -e --arg path "${newline_dir:A}" '.harness.sandbox_read_paths[-1] == $path' \
  <<<"$output" >/dev/null || fail 'newline-containing sandbox path was not frozen exactly'
HOME="$tmp" zsh -f "$entry" config --config "$config" --sandbox-write '~/added' >/dev/null || \
  fail '--sandbox-write rejected a home-relative path'
zsh -f "$entry" config --config "$config" --sandbox-read "$tmp/missing" >/dev/null 2>&1 && \
  fail '--sandbox-read accepted a missing path'

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
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --session "$forwarded_session" \
  --config "$config" --model forwarded-model 'plain answer') || fail 'forwarded run failed'
assert_equal 'plain answer' "$output" 'run keeps the prompt after a forwarded value'
head -n 1 "$forwarded_session" | jq -e '.profile.request.model == "forwarded-model"' \
  >/dev/null || fail 'a forwarded option value did not reach the new session'

# Exec no longer creates sessions; shellfish create supplies the one the
# read-only request commands compose against.
typeset request_session
request_session=$(zsh -f "$entry" create --config "$config") || fail 'create failed'
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$request_session"
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"answer"}]}' \
  >>"$request_session"

# Read-only request commands compose one provider call without claiming or
# mutating the durable turn.
typeset request_record request_response request_digest
print -r -- '{}' | zsh -f "$entry" build-request --session "$tmp/missing.jsonl" \
  >/dev/null 2>&1 && fail 'build-request accepted a missing session'
print -r -- '{}' | zsh -f "$entry" send-request --session "$tmp/missing.jsonl" \
  >/dev/null 2>&1 && fail 'send-request accepted a missing session'
zsh -f "$entry" build-request --session "$request_session" --tools '{}' \
  >/dev/null 2>&1 && fail 'build-request accepted invalid tools'
zsh -f "$entry" build-request --session "$request_session" --tools '[{}]' \
  >/dev/null 2>&1 && fail 'build-request accepted an invalid tool schema'
request_record=$(jq -cn --arg text 'composed request' \
  '{type:"message",role:"user",content:[{type:"text",text:$text}]}')
request_digest=$(shasum <"$request_session")
request=$(print -r -- "$request_record" |
  zsh -f "$entry" build-request --session "$request_session" --tools '[]') ||
  fail 'build-request failed'
jq -e '
  .tools == [] and .messages[-1] == {
    role:"user",content:[{type:"text",text:"composed request"}]
  }
' <<<"$request" >/dev/null || fail 'build-request produced the wrong request'
request_response=$(print -r -- "$request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" send-request --session "$request_session") ||
  fail 'send-request failed'
jq -e '
  .type == "message" and .role == "assistant" and .stop == "end" and
  .content == [{type:"text",text:"composed request\n"}]
' <<<"$request_response" >/dev/null || fail 'send-request produced the wrong response'
assert_equal "$request_digest" "$(shasum <"$request_session")"

print -r -- '{"type":"message","role":"assistant","stop":"end","content":[]}' |
  zsh -f "$entry" build-request --session "$request_session" >/dev/null 2>&1 &&
  fail 'build-request accepted an invalid record transition'
print -r -- '{}' | zsh -f "$entry" send-request --session "$request_session" \
  >/dev/null 2>&1 && fail 'send-request accepted an invalid request'
printf '%s\n%s\n' "$request" "$request" |
  zsh -f "$entry" send-request --session "$request_session" >/dev/null 2>&1 &&
  fail 'send-request accepted multiple requests'
jq '.transport.endpoint = "https://elsewhere.invalid"' <<<"$request" |
  zsh -f "$entry" send-request --session "$request_session" >/dev/null 2>&1 &&
  fail 'send-request accepted transport from outside the frozen runtime'
typeset separator_request separator_response
separator_request=$(jq --arg text $'record separator: \x1e' \
  '.messages[-1].content[0].text = $text' <<<"$request")
separator_response=$(print -r -- "$separator_request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" send-request --session "$request_session") ||
  fail 'send-request rejected valid assistant text'
jq -e --arg text $'record separator: \x1e\n' '.content[0].text == $text' \
  <<<"$separator_response" >/dev/null || fail 'send-request changed assistant text'
typeset failing_request
failing_request=$(jq '.messages[-1].content[0].text = "error"' <<<"$request")
print -r -- "$failing_request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" send-request --session "$request_session" \
    >/dev/null 2>"$tmp/send-request-error" && fail 'send-request accepted backend failure'
[[ $(<"$tmp/send-request-error") == *'test backend failure'* ]] ||
  fail 'send-request hid the backend error'

# JSONL exposes the canonical turn stream through EOF and process status. The
# session prefix is created before the turn and is not replayed onto the stream.
typeset jsonl stream_session="$tmp/stream.jsonl"
zsh -f "$entry" create --path "$stream_session" --config "$config" >/dev/null ||
  fail 'stream session create failed'
typeset -i prefix=$(jq -es 'length' "$stream_session")
jsonl=$(print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"stream answer"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --jsonl --config "$config" \
    --session "$stream_session") || fail 'JSONL run failed'
print -r -- "$jsonl" | jq -eRn -L "$ROOT" '
  include "lib/runtime/schema";
  [inputs | fromjson] as $events |
  ($events | any(.type == "session") | not) and
  ($events | any(.type == "_assistant_delta")) and
  ($events | any(.type == "_turn_usage")) and
  ($events | any(.type == "message" and .role == "user")) and
  ($events | any(.type == "message" and .role == "assistant"))
' >/dev/null || fail 'JSONL run produced the wrong stream'

print -r -- "$jsonl" | jq -c 'select(.type | IN("session", "system", "message", "context"))' \
  >"$tmp/stream-durable"
jq -c . "$stream_session" | tail -n +$(( prefix + 1 )) >"$tmp/session-durable"
cmp -s "$tmp/stream-durable" "$tmp/session-durable" ||
  fail 'JSONL durable events differ from the appended session records'

# A bounded turn emits an arbitrary command handoff and completes cleanly.
typeset handoff_script="$tmp/handoff"
cat >"$handoff_script" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == user_prompt_submit ]] || exit 1
print -rn -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
exit 11
ZSH
chmod +x "$handoff_script"
typeset handoff_config="$tmp/handoff.jsonc" handoff_output="$tmp/handoff.jsonl"
jq --arg script "$handoff_script" '.harnesses.machine.user_prompt_submit=[$script]' \
  "$config" >"$handoff_config"
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"handoff"}]}' |
  zsh -f "$entry" run --jsonl --config "$handoff_config" \
  >"$handoff_output" || fail 'JSONL run rejected a handoff'
jq -eRn '
  [inputs | fromjson] as $events |
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  ($events | any(.type == "_turn_error" or .role == "user") | not)
' <"$handoff_output" >/dev/null || fail 'JSONL run discarded the handoff'

# Session creation and its session_start failures belong to shellfish create.

typeset invalid_path="$tmp/invalid-path" invalid_path_output="$tmp/invalid-path.out"
ln -s "$config" "$invalid_path"
integer invalid_path_status=0
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"ignored"}]}' |
  zsh -f "$entry" run --jsonl --session "$invalid_path" \
  >"$invalid_path_output" 2>"$tmp/invalid-path.stderr" || invalid_path_status=$?
(( invalid_path_status == 1 ))
[[ ! -s $tmp/invalid-path.stderr ]]
jq -eRn --arg path "$invalid_path" '
  [inputs | fromjson] == [{type:"_turn_error",message:("invalid session path: " + $path)}]
' <"$invalid_path_output" >/dev/null ||
  fail 'JSONL prepare failure was not emitted as a turn error'

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
zsh -f "$entry" run --verbose --config "$config" hi >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'run accepted --verbose'
exit_code=0
zsh -f "$entry" run --new --config "$config" >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'run accepted --new'

print -r -- 'ok'
