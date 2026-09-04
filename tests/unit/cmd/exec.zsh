#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp exec-command
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
  zsh -f "$entry" exec --config "$verbose_config" test || fail 'verbose exec failed'
assert_equal 1 "$(<"$tmp/verbose-one")"
SF_VERBOSE_MARKER="$tmp/verbose-invalid" SHELLFISH_VERBOSE=invalid \
  zsh -f "$entry" exec --config "$verbose_config" test || fail 'normalized exec failed'
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
output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" exec --config "$config" 'plain answer') || \
  fail 'plain exec failed'
assert_equal 'plain answer' "$output" 'plain exec prints only the answer'

integer failed_status=0
SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" exec --config "$config" \
  'retry error later' >/dev/null 2>&1 || failed_status=$?
(( failed_status == 1 )) || fail 'recoverable turn failure exited successfully'

output=$(print -rn -- 'piped answer' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" exec --config "$config") || \
  fail 'piped exec failed'
assert_equal 'piped answer' "$output" 'exec accepts standard input'

output=$(SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" exec --config "$config" \
  several prompt words) || fail 'multi-argument exec failed'
assert_equal 'several prompt words' "$output" 'exec joins positional prompt words'

# --new creates only the durable session prefix and returns its path.
typeset new_session
new_session=$(zsh -f "$entry" exec --new --config "$config") || fail 'new exec failed'
[[ -f $new_session && $new_session == /* ]] || fail 'new exec did not return its session path'
jq -es 'length == 2 and .[0].type == "session" and
  .[1] == {type:"system",content:"initial system"}' \
  "$new_session" >/dev/null || fail 'new exec did not create the initial session prefix'

# An optional source session reuses its frozen runtime, rematerializes its system
# components, and does not copy transcript records.
print -r -- 'rematerialized system' >"$tmp/system/source.md"
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$new_session"
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"answer"}]}' \
  >>"$new_session"
typeset reused_session
reused_session=$(zsh -f "$entry" exec --new "$new_session") || fail 'sourced new exec failed'
jq -e -s --slurpfile source "$new_session" '
  length == 2 and .[1] == {type:"system",content:"rematerialized system"} and
  (.[0] | del(.created)) == ($source[0] | del(.created))
' "$reused_session" >/dev/null || fail 'new exec did not reuse only source settings'

# Read-only request commands compose one provider call without claiming or
# mutating the durable turn.
typeset request_record request_response request_digest
print -r -- '{}' | zsh -f "$entry" build-request --session "$tmp/missing.jsonl" \
  >/dev/null 2>&1 && fail 'build-request accepted a missing session'
print -r -- '{}' | zsh -f "$entry" run-request --session "$tmp/missing.jsonl" \
  >/dev/null 2>&1 && fail 'run-request accepted a missing session'
zsh -f "$entry" build-request --session "$new_session" --tools '{}' \
  >/dev/null 2>&1 && fail 'build-request accepted invalid tools'
zsh -f "$entry" build-request --session "$new_session" --tools '[{}]' \
  >/dev/null 2>&1 && fail 'build-request accepted an invalid tool schema'
request_record=$(jq -cn --arg text 'composed request' \
  '{type:"message",role:"user",content:[{type:"text",text:$text}]}')
request_digest=$(shasum <"$new_session")
zmodload zsh/system
integer request_lock
: >"${new_session}.lock"
zsystem flock -f request_lock "${new_session}.lock" || fail 'cannot hold request test lock'
request=$(print -r -- "$request_record" |
  zsh -f "$entry" build-request --session "$new_session" --tools '[]') ||
  fail 'build-request failed while the source was locked'
jq -e '
  .tools == [] and .messages[-1] == {
    role:"user",content:[{type:"text",text:"composed request"}]
  }
' <<<"$request" >/dev/null || fail 'build-request produced the wrong request'
request_response=$(print -r -- "$request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run-request --session "$new_session") ||
  fail 'run-request failed while the source was locked'
jq -e '
  .type == "message" and .role == "assistant" and .stop == "end" and
  .content == [{type:"text",text:"composed request\n"}]
' <<<"$request_response" >/dev/null || fail 'run-request produced the wrong response'
zsystem flock -u "$request_lock" || fail 'cannot release request test lock'
assert_equal "$request_digest" "$(shasum <"$new_session")"

print -r -- '{"type":"message","role":"assistant","stop":"end","content":[]}' |
  zsh -f "$entry" build-request --session "$new_session" >/dev/null 2>&1 &&
  fail 'build-request accepted an invalid record transition'
print -r -- '{}' | zsh -f "$entry" run-request --session "$new_session" \
  >/dev/null 2>&1 && fail 'run-request accepted an invalid request'
printf '%s\n%s\n' "$request" "$request" |
  zsh -f "$entry" run-request --session "$new_session" >/dev/null 2>&1 &&
  fail 'run-request accepted multiple requests'
jq '.transport.endpoint = "https://elsewhere.invalid"' <<<"$request" |
  zsh -f "$entry" run-request --session "$new_session" >/dev/null 2>&1 &&
  fail 'run-request accepted transport from outside the frozen runtime'
typeset separator_request separator_response
separator_request=$(jq --arg text $'record separator: \x1e' \
  '.messages[-1].content[0].text = $text' <<<"$request")
separator_response=$(print -r -- "$separator_request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run-request --session "$new_session") ||
  fail 'run-request rejected valid assistant text'
jq -e --arg text $'record separator: \x1e\n' '.content[0].text == $text' \
  <<<"$separator_response" >/dev/null || fail 'run-request changed assistant text'
typeset failing_request
failing_request=$(jq '.messages[-1].content[0].text = "error"' <<<"$request")
print -r -- "$failing_request" |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run-request --session "$new_session" \
    >/dev/null 2>"$tmp/run-request-error" && fail 'run-request accepted backend failure'
[[ $(<"$tmp/run-request-error") == *'test backend failure'* ]] ||
  fail 'run-request hid the backend error'

# JSONL exposes the canonical exec stream through EOF and process status.
typeset jsonl stream_session="$tmp/stream.jsonl"
jsonl=$(print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"stream answer"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" exec --jsonl --config "$config" \
    --session "$stream_session") || fail 'JSONL exec failed'
print -r -- "$jsonl" | jq -eRn -L "$ROOT/lib" '
  include "runtime/schema";
  [inputs | fromjson] as $events |
  ($events[0] | canonical_session_header(1)) and
  ($events | any(.type == "_assistant_delta")) and
  ($events | any(.type == "_turn_usage")) and
  ($events | any(.type == "message" and .role == "user")) and
  ($events | any(.type == "message" and .role == "assistant"))
' >/dev/null

print -r -- "$jsonl" | jq -c 'select(.type | IN("session", "system", "message", "context"))' \
  >"$tmp/stream-durable"
jq -c . "$stream_session" >"$tmp/session-durable"
cmp -s "$tmp/stream-durable" "$tmp/session-durable" ||
  fail 'JSONL durable events differ from the appended session records'

# A bounded exec emits an arbitrary command handoff and completes cleanly.
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
  zsh -f "$entry" exec --jsonl --config "$handoff_config" \
  >"$handoff_output" || fail 'JSONL exec rejected a handoff'
jq -eRn '
  [inputs | fromjson] as $events |
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  ($events | any(.type == "_exec_error" or .role == "user") | not)
' <"$handoff_output" >/dev/null || fail 'JSONL exec discarded the handoff'

# A session_start skip status fails without creating a session.
typeset skip_script="$tmp/skip-start"
cat >"$skip_script" <<'ZSH'
#!/usr/bin/env zsh
[[ $SHELLFISH_MODE == exec && $# == 1 && $1 == session_start ]] || exit 1
print -n 'startup context'
print -n -u2 'startup display'
exit 10
ZSH
chmod +x "$skip_script"
typeset skip_config="$tmp/skip-start.jsonc"
jq --arg script "$skip_script" '.harnesses.machine.session_start=[$script]' \
  "$config" >"$skip_config"
typeset skip_session="$tmp/skipped.jsonl" skip_stderr="$tmp/skipped.stderr"
integer skip_status=0
output=$(zsh -f "$entry" exec --session "$skip_session" --config "$skip_config" \
  ignored 2>"$skip_stderr") || skip_status=$?
(( skip_status == 1 ))
[[ -z $output && $(<"$skip_stderr") == *'session_start hook script returned unsupported skip status'* ]]
[[ ! -e $skip_session ]]

typeset jsonl_skip_session="$tmp/jsonl-skipped.jsonl" jsonl_skip_stderr="$tmp/jsonl-skipped.stderr"
skip_status=0
jsonl=$(print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"ignored"}]}' |
  zsh -f "$entry" exec --jsonl --session "$jsonl_skip_session" \
    --config "$skip_config" 2>"$jsonl_skip_stderr") || skip_status=$?
(( skip_status == 1 ))
[[ ! -s $jsonl_skip_stderr ]]
print -r -- "$jsonl" | jq -eRn -L "$ROOT/lib" '
  [inputs | fromjson] as $events |
  ($events | length) == 2 and
  ($events[0] | .type == "_hook_display" and .hook == "session_start" and
    .text == "startup display" and .complete == true) and
  ($events[1] == {type:"_exec_error",
    message:"session_start hook script returned unsupported skip status"})
' >/dev/null || fail 'JSONL creation failure did not emit its error'
[[ ! -e $jsonl_skip_session ]]

typeset invalid_path="$tmp/invalid-path" invalid_path_output="$tmp/invalid-path.out"
ln -s "$config" "$invalid_path"
integer invalid_path_status=0
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"ignored"}]}' |
  zsh -f "$entry" exec --jsonl --session "$invalid_path" \
  >"$invalid_path_output" 2>"$tmp/invalid-path.stderr" || invalid_path_status=$?
(( invalid_path_status == 1 ))
[[ ! -s $tmp/invalid-path.stderr ]]
jq -eRn --arg path "$invalid_path" '
  [inputs | fromjson] == [{type:"_exec_error",message:("invalid session path: " + $path)}]
' <"$invalid_path_output" >/dev/null ||
  fail 'JSONL prepare failure was not emitted as an exec error'

integer exit_code=0
print -n piped | zsh -f "$entry" exec --config "$config" argument >/dev/null 2>&1 || \
  exit_code=$?
(( exit_code == 2 )) || fail 'exec accepted prompt argument and stdin together'
exit_code=0
print -n '{}' | zsh -f "$entry" exec --jsonl --config "$config" >/dev/null 2>&1 || \
  exit_code=$?
(( exit_code == 2 )) || fail 'exec accepted noncanonical JSON input'
exit_code=0
zsh -f "$entry" --jsonl >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'chat accepted --jsonl'
exit_code=0
zsh -f "$entry" exec --verbose --config "$config" hi >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'exec accepted --verbose'
exit_code=0
zsh -f "$entry" exec --new --config "$config" one two >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'new exec accepted more than one source session'
exit_code=0
zsh -f "$entry" exec --new --jsonl --config "$config" >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'new exec accepted JSONL mode'

print -r -- 'ok'
