#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-create-command
sf_test_config
typeset system="$SF_TEST_CONFIG/profiles/default/system"
mkdir -p "$tmp/home" "$system"
print -r -- 'initial system' >"$system/source.md"
export HOME="${tmp:A}/home"
export XDG_STATE_HOME="$tmp/state"

sf_test_profile default "{
  \"backend\": {\"adapter\": \"$ROOT/tests/fixtures/backend\"},
  \"system\": [\"source.md\"],
  \"request\": {\"model\": \"test-model\"},
  \"tools\": []
}"

typeset entry="$ROOT/bin/shellfish"
typeset created reused explicit

# Create a complete idle session.
created="$tmp/created.jsonl"
zsh -f "$entry" run --jsonl --session-create --session-out "$created" \
  >/dev/null || fail 'create failed'
[[ -f $created && $created == /* ]] || fail 'run did not create the session'
jq -es 'length == 2 and .[0].type == "session" and
  .[1] == {type:"system",content:"initial system"}' \
  "$created" >/dev/null || fail 'create did not write the initial session prefix'

# Select an explicit destination.
explicit="$tmp/explicit.jsonl"
zsh -f "$entry" run --session-create --session-out "$explicit" ||
  fail 'run ignored --session-out'
jq -es 'length == 2' "$explicit" >/dev/null || fail 'create did not populate --session-out'

# Freeze forwarded sandbox grants.
typeset granted="$tmp/granted.jsonl"
zsh -f "$entry" run --session-create --session-out "$granted" \
  --sandbox-read "${system:A}" --sandbox-write "${tmp:A}/home" >/dev/null || \
  fail 'create rejected forwarded sandbox grants'
jq -e --arg read "${system:A}" '
  select(.type == "session") |
  (.runtime.harness.sandbox_read_paths | index($read)) != null and
  (.runtime.harness.sandbox_write_paths | index("~")) != null
' "$granted" >/dev/null || fail 'create did not store forwarded sandbox grants'

# Derived sessions reuse runtime and reread system paths.
print -r -- 'changed configured system' >"$system/source.md"
print -r -- '{"type":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$created"
reused="$tmp/reused.jsonl"
zsh -f "$entry" run --session-create --session-from "$created" --session-out "$reused" ||
  fail 'sourced create failed'
jq -e -s --slurpfile source "$created" '
  length == 2 and .[1] == {type:"system",content:"changed configured system"} and
  (.[0] | del(.created)) == ($source[0] | del(.created))
' "$reused" >/dev/null || fail 'create did not reuse the stored runtime'

# Reject a missing source.
zsh -f "$entry" run --session-create --session-from "$tmp/absent.jsonl" >/dev/null 2>&1 &&
  fail 'create accepted a missing source'

# Preserve occupied destinations.
zsh -f "$entry" run --session-create --session-out "$explicit" >/dev/null 2>&1 &&
  fail 'create overwrote an existing session'

# Reject overrides for stored sessions.
zsh -f "$entry" run --session-create --session-from "$created" --model other >/dev/null 2>&1 &&
  fail 'create accepted a runtime override with --session-from'

# Retain the valid prefix and failed result from startup hooks.
typeset hook="$tmp/failing-hook"
mkdir "$hook"
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 0 && -z ${SHELLFISH_TURN_STATE-} ]] || exit 2
print -u2 -r -- 'startup detail'
exit 9
ZSH
chmod +x "$hook/run"
sf_test_profile hook \
  "{\"extend\": [\"default\"], \"hooks\": {\"session_start\": [\"$hook\"]}}"
typeset failed="$tmp/failed.jsonl" hook_error="$tmp/hook-error"
zsh -f "$entry" run --session-create --session-out "$failed" \
  -p hook >/dev/null 2>"$hook_error" &&
  fail 'a failing session_start script created a session'
[[ $(<"$hook_error") == *"hook script failed with status 9: ${hook:A}/run: startup detail"* ]] ||
  fail 'create hid the session_start failure'
[[ -f $failed ]] || fail 'create removed the failed startup transcript'
jq -se 'map(.type) == ["session","system","hook_result"] and .[-1].exit_code == 9' \
  "$failed" >/dev/null || fail 'create did not retain the failed startup result'

# Join system components in order.
typeset joined="$tmp/joined.jsonl"
printf 'first prompt\n\n\n' >"$system/first.md"
printf 'second prompt\n' >"$system/second.md"
sf_test_profile joined \
  '{"extend": ["default"], "system": ["first.md", "second.md"]}' 
zsh -f "$entry" run --session-create --session-out "$joined" -p joined >/dev/null ||
  fail 'multi-component create failed'
jq -se 'length == 2 and .[1] == {type:"system",content:"first prompt\n\nsecond prompt"}' \
  "$joined" >/dev/null || fail 'create did not join the system components'

# Preserve mixed system override order.
typeset override="$tmp/override.jsonl" override_file="$tmp/override.md" derived
printf 'file prompt\n' >"$override_file"
zsh -f "$entry" run --session-create --session-out "$override" \
  --system $'inline\nprompt\n\n' --system-file "$override_file" --system 'last prompt' \
  >/dev/null || fail 'create rejected system overrides'
jq -se '
  length == 2 and
  (.[0].runtime.system | length) == 1 and
  .[1] == {type:"system",content:"inline\nprompt\n\nfile prompt\n\nlast prompt"}
' "$override" >/dev/null || fail 'create did not materialize ordered system overrides'
printf 'updated file prompt\n' >"$override_file"
jq -c 'if .type == "system" then .content += "\n\n" else . end' "$override" \
  >"$tmp/stored-system.jsonl"
mv "$tmp/stored-system.jsonl" "$override"
derived="$tmp/derived.jsonl"
zsh -f "$entry" run --session-create --session-from "$override" --session-out "$derived" || \
  fail 'create did not reuse the stored system paths'
jq -se '
  length == 2 and
  .[1] == {type:"system",content:"changed configured system"}
' "$derived" >/dev/null || fail 'create did not rematerialize the stored system paths'
typeset derived_override="$tmp/derived-override.jsonl"
zsh -f "$entry" run --session-create --session-out "$derived_override" --session-from "$override" \
  --system '--session-out' >/dev/null || fail 'derived create rejected option-looking system text'
jq -se 'length == 2 and .[1] == {type:"system",content:"--session-out"}' \
  "$derived_override" >/dev/null || fail 'derived create did not apply the system override'

# Clear prompts with empty overrides.
typeset empty_file="$tmp/empty.md" empty_session
printf '\n\n' >"$empty_file"
for source in profile session; do
  typeset -a origin=( -p default )
  [[ $source != session ]] || origin=( --session-from "$override" )
  empty_session="$tmp/empty-$source.jsonl"
  zsh -f "$entry" run --session-create --session-out "$empty_session" "${origin[@]}" \
    --system '' --system-file "$empty_file" || fail 'empty system override failed'
  jq -se 'length == 1' "$empty_session" >/dev/null || fail 'empty override retained a system record'
done

# Reject unreadable system components.
typeset missing="$tmp/missing.jsonl"
sf_test_profile missing-system \
  "{\"extend\": [\"default\"], \"system\": [\"$tmp/absent.md\"]}"
zsh -f "$entry" run --session-create --session-out "$missing" -p missing-system >/dev/null 2>&1 &&
  fail 'a missing system component created a session'
[[ ! -e $missing ]] || fail 'create left a transcript for a missing component'
zsh -f "$entry" run --session-create --session-out "$missing" \
  --system-file "$tmp/absent.md" >/dev/null 2>&1 &&
  fail 'create accepted a missing system override file'
[[ ! -e $missing ]] || fail 'missing system override left a transcript'

# Reject system input that cannot survive shell transport intact.
typeset binary="$tmp/binary.jsonl" binary_file="$tmp/binary.md"
printf 'before\0after\n' >"$binary_file"
zsh -f "$entry" run --session-create --session-out "$binary" \
  --system-file "$binary_file" >/dev/null 2>&1 &&
  fail 'create accepted system content containing NUL bytes'
[[ ! -e $binary ]] || fail 'binary system input left a transcript'

# Startup records are durable before the next component runs.
typeset events="$tmp/events.jsonl" streamed="$tmp/streamed.jsonl"
typeset first="$tmp/first-hook" silent="$tmp/silent-hook"
mkdir "$first" "$silent"
cat >"$first/run" <<'ZSH'
#!/usr/bin/env zsh
[[ -f $SHELLFISH_SESSION ]] || exit 2
jq -se 'map(.type) == ["_session_load","session","system","_hook_activity"]' \
  "$SF_TEST_EVENTS" >/dev/null || exit 3
print -r -- 'startup context'
printf '%*s' "${SF_TEST_CONTEXT_BYTES:-0}" ''
print -rn -u3 -- '{"state":[{"name":"startup/stream","value":true}]}'
print -u2 -r -- 'startup display'
ZSH
cat >"$silent/run" <<'ZSH'
#!/usr/bin/env zsh
[[ -f $SHELLFISH_SESSION ]] || exit 2
# Each durable startup record reaches the stream before the next hook runs.
jq -se 'map(.type) == ["_session_load","session","system","_hook_activity",
  "state","hook_result","_hook_activity"]' \
  "$SF_TEST_EVENTS" >/dev/null || exit 3
jq -se '.[-2] == {type:"state",name:"startup/stream",value:true} and
  .[-1].type == "hook_result" and .[-1].name == "first-hook"' \
  "$SHELLFISH_SESSION" >/dev/null || exit 4
ZSH
print -r -- '{}' >"$first/manifest.json"
chmod +x "$first/run" "$silent/run"
sf_test_profile stream \
  "{\"extend\": [\"default\"], \"hooks\": {\"session_start\": [\"$first\", \"$silent\"]}}"
SF_TEST_EVENTS="$events" zsh -f "$entry" run --jsonl --session-create -p stream \
  --session-out "$streamed" >"$events" 2>"$hook_error" || fail 'streamed creation failed'
[[ ! -s $hook_error ]] || fail "streamed display leaked to stderr: $(<"$hook_error")"
jq -se --arg path "$streamed" --arg first "${first:A}/run" --arg silent "${silent:A}/run" \
  --slurpfile session "$streamed" '
  map(.type) == ["_session_load","session","system","_hook_activity",
    "state","hook_result","_hook_activity"] and
  .[0] == {type:"_session_load",path:$path} and
  .[1:3] == $session[0:2] and
  (.[3] | del(.id)) == {type:"_hook_activity",hook:"session_start",name:"first-hook",
    executable:$first,input:""} and
  # A hook that captured nothing records no result.
  (.[6] | del(.id)) == {type:"_hook_activity",hook:"session_start",name:"silent-hook",
    executable:$silent,input:""} and
  .[4:6] == $session[2:] and
  .[5].lifecycle == "session_start" and .[5].name == "first-hook" and
  .[5].input == "" and .[5].exit_code == 0 and
  .[5].user_text == "startup display\n" and
  (.[5].model_text | startswith("startup context\n")) and
  .[3].id == .[5].id
' "$events" >/dev/null || fail 'invalid creation event sequence or transcript'

# A failed later startup retains and streams the completed prefix and result.
sf_test_profile stream \
  "{\"extend\": [\"hook\"], \"hooks\": {\"session_start\": [\"$first\", \"...\"]}}"
failed="$tmp/later-failed.jsonl"
SF_TEST_EVENTS="$events" zsh -f "$entry" run --jsonl --session-create \
  --session-out "$failed" -p stream >"$events" 2>"$hook_error" &&
  fail 'a later startup failure succeeded'
[[ -f $failed && $(<"$hook_error") == *'hook script failed with status 9:'* ]] ||
  fail 'failed startup did not retain its session and diagnostic'
jq -se '
  map(.type) == ["_session_load","session","system","_hook_activity","state",
    "hook_result","_hook_activity","hook_result"] and
  .[-1].exit_code == 9
' "$events" >/dev/null || fail 'a failed creation lost its durable prefix'
jq -se '
  map(.type) == ["session","system","state","hook_result","hook_result"] and
  .[-1].exit_code == 9
' "$failed" >/dev/null || fail 'a failed creation lost its durable prefix'

# Cancel running startup scripts.
typeset slow="$tmp/slow-hook" cancelled="$tmp/cancelled.jsonl"
export SLOW_MARKER="$tmp/slow-active" SLOW_RELEASE="$tmp/slow-release"
export SLOW_EXIT_MARKER="$tmp/slow-exit"
mkdir "$slow"
cat >"$slow/run" <<'ZSH'
#!/usr/bin/env zsh
: >"$SLOW_MARKER"
# Release detects scripts that survive cancellation.
while [[ ! -e $SLOW_RELEASE ]]; do
  sleep 0.05
done
: >"$SLOW_EXIT_MARKER"
ZSH
chmod +x "$slow/run"
sf_test_profile slow \
  "{\"extend\": [\"default\"], \"hooks\": {\"session_start\": [\"$slow\"]}}"
zsh -f "$entry" run --jsonl --session-create -p slow --session-out "$cancelled" \
  >"$events" 2>"$hook_error" &
integer create_pid=$! cancel_status=0 waited=0
while (( waited++ < 50 )) && [[ ! -e $SLOW_MARKER ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'session_start hook script did not start'
kill -USR1 "$create_pid"
wait "$create_pid" || cancel_status=$?
(( cancel_status == 130 )) || fail 'cancelled creation did not report cancellation'
[[ -f $cancelled ]] || fail 'cancelled creation removed its transcript'
: >"$SLOW_RELEASE"
sleep 0.3
[[ ! -e $SLOW_EXIT_MARKER ]] || fail 'cancelled session_start hook script ran to completion'
jq -se 'map(.type) == ["_session_load","session","system","_hook_activity"]' \
  "$events" >/dev/null || fail 'cancelled creation lost its durable prefix'
jq -se 'map(.type) == ["session","system"]' "$cancelled" >/dev/null ||
  fail 'cancelled creation lost its transcript prefix'
[[ -s $hook_error ]] || fail 'cancelled creation omitted stderr diagnostic'

# Moving a home and project preserves their frozen relative references.
typeset old_home="$tmp/original-home" new_home="$tmp/moved-home"
typeset old_project="$old_home/project" new_project="$new_home/project"
mkdir -p "$old_project/hook" "$old_home/.config/shellfish/profiles/default"
print -r -- 'original prompt' >"$old_project/prompt.md"
cat >"$old_project/hook/run" <<'ZSH'
#!/usr/bin/env zsh
pwd -P >"$PWD/hook-cwd"
ZSH
chmod +x "$old_project/hook/run"
cat >"$old_home/.config/shellfish/profiles/default/profile.jsonc" <<EOF
{
  "backend": {"adapter": "$ROOT/tests/fixtures/backend"},
  "request": {"model": "test-model"},
  "system": ["$old_project/prompt.md"],
  "tools": [], "hooks": {"user_prompt_submit": ["$old_project/hook"]}
}
EOF
(
  builtin cd -- "$old_project"
  HOME="$old_home" XDG_CONFIG_HOME="$old_home/.config" zsh -f "$entry" run \
    --session-create --session-out "$PWD/session.jsonl"
) || fail 'portable session creation failed'
jq -e 'select(.type == "session") |
  .cwd == "~/project" and .runtime.system == ["./prompt.md"] and
  .runtime.harness.user_prompt_submit[0].command == "./hook/run"
' "$old_project/session.jsonl" >/dev/null || fail 'session did not store portable paths'
mv -- "$old_home" "$new_home"
(
  builtin cd -- "$new_project"
  HOME="$new_home" XDG_CONFIG_HOME="$new_home/.config" SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run \
    --session "$PWD/session.jsonl" 'plain answer' >"$tmp/relocated-answer"
) || fail 'relocated session turn failed'
assert_equal 'plain answer' "$(<"$tmp/relocated-answer")"
assert_equal "${new_project:A}" "$(<"$new_project/hook-cwd")" \
  'relocated hook ran outside the project'
print -r -- 'moved prompt' >"$new_project/prompt.md"
(
  builtin cd -- "$new_project"
  HOME="$new_home" XDG_CONFIG_HOME="$new_home/.config" zsh -f "$entry" run --session-create \
    --session-from "$PWD/session.jsonl" --session-out "$PWD/derived.jsonl"
) || fail 'relocated session could not be derived'
jq -e -s '.[1] == {type:"system",content:"moved prompt"}' \
  "$new_project/derived.jsonl" >/dev/null || fail 'derived session read the old project path'

print -r -- ok
