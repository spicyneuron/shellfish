#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-create-command
sf_test_config
typeset system="$SF_TEST_CONFIG/system"
mkdir -p "$tmp/home/work" "$system"
print -r -- 'initial system' >"$system/source.md"
export HOME="${tmp:A}/home"

sf_test_model default "{
  \"provider\": \"$ROOT/tests/fixtures/provider\",
  \"request\": {\"model\": \"test-model\"}
}"
sf_test_profile default '{"system": ["source.md"]}'

typeset entry="$ROOT/bin/shellfish"
typeset created reused explicit

# Create a complete idle session.
created="$tmp/created.jsonl"
zsh -f "$entry" run --jsonl --session-create --session-out "$created" \
  >/dev/null || fail 'create failed'
[[ -f $created && $created == /* ]] || fail 'run did not create the session'
jq -es 'length == 1 and .[0].type == "session" and
  .[0].profile.system == [{text:"initial system"}]' \
  "$created" >/dev/null || fail 'create did not write the initial session header'

# Select an explicit destination.
explicit="$tmp/explicit.jsonl"
zsh -f "$entry" run --session-create --session-out "$explicit" ||
  fail 'run ignored --session-out'
jq -es 'length == 1' "$explicit" >/dev/null || fail 'create did not populate --session-out'

# Freeze forwarded sandbox grants.
typeset granted="$tmp/granted.jsonl"
zsh -f "$entry" run --session-create --session-out "$granted" \
  --sandbox "{\"read\": [\"${system:A}\"], \"write\": [\"~/work\"]}" >/dev/null || \
  fail 'create rejected forwarded sandbox grants'
jq -e --arg read "${system:A}" '
  select(.type == "session") |
  (.profile.sandbox.read | index($read)) != null and
  (.profile.sandbox.write | index("~/work")) != null
' "$granted" >/dev/null || fail 'create did not store forwarded sandbox grants'

# Derived sessions reuse the frozen profile, system text included.
print -r -- 'changed configured system' >"$system/source.md"
print -r -- '{"type":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$created"
reused="$tmp/reused.jsonl"
zsh -f "$entry" run --session-create --session-from "$created" --session-out "$reused" ||
  fail 'sourced create failed'
jq -e -s --slurpfile source "$created" '
  length == 1 and .[0].profile.system == [{text:"initial system"}] and
  (.[0] | del(.created)) == ($source[0] | del(.created))
' "$reused" >/dev/null || fail 'create did not reuse the stored profile'

# Reject a missing source.
zsh -f "$entry" run --session-create --session-from "$tmp/absent.jsonl" >/dev/null 2>&1 &&
  fail 'create accepted a missing source'

# Preserve occupied destinations.
zsh -f "$entry" run --session-create --session-out "$explicit" >/dev/null 2>&1 &&
  fail 'create overwrote an existing session'

# Reject overrides for stored sessions.
zsh -f "$entry" run --session-create --session-from "$created" --model test >/dev/null 2>&1 &&
  fail 'create accepted a profile override with --session-from'

# Retain the valid prefix when a startup hook fails.
typeset hook="$tmp/failing-hook"
sf_test_hook "$hook" '{"on":"session_start"}' <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 0 && -z ${SHELLFISH_TURN_STATE-} ]] || exit 2
print -u2 -r -- 'startup detail'
exit 9
ZSH
sf_test_profile hook \
  "{\"system\": [\"source.md\"], \"hooks\": [\"$hook\"]}"
typeset failed="$tmp/failed.jsonl" hook_error="$tmp/hook-error"
zsh -f "$entry" run --session-create --session-out "$failed" \
  -p hook >/dev/null 2>"$hook_error" &&
  fail 'a failing session_start script created a session'
[[ $(<"$hook_error") == *"session_start hook failed with status 9: ${hook:A}: startup detail"* ]] ||
  fail 'create hid the session_start failure'
[[ -f $failed ]] || fail 'create removed the failed startup transcript'
jq -se 'map(.type) == ["session"]' \
  "$failed" >/dev/null || fail 'create did not retain the failed startup prefix'

# Join system components in order.
typeset joined="$tmp/joined.jsonl"
printf 'first prompt\n\n\n' >"$system/first.md"
printf 'second prompt\n' >"$system/second.md"
sf_test_profile joined '{"system": ["first.md", "second.md"]}'
zsh -f "$entry" run --session-create --session-out "$joined" -p joined >/dev/null ||
  fail 'multi-component create failed'
jq -se '.[0].profile.system == [{text:"first prompt\n\nsecond prompt"}]' \
  "$joined" >/dev/null || fail 'create did not join the system components'

# System options append after the profile's prompts, in order.
typeset override="$tmp/override.jsonl" override_file="$tmp/override.md" derived
printf 'file prompt\n' >"$override_file"
zsh -f "$entry" run --session-create --session-out "$override" \
  --system '{"text":"inline\nprompt\n\n"}' --system "$override_file" \
  --system '{"text":"last prompt"}' >/dev/null || fail 'create rejected system options'
jq -se '
  .[0].profile.system == [{
    text:"changed configured system\n\ninline\nprompt\n\nfile prompt\n\nlast prompt"}]
' "$override" >/dev/null || fail 'create did not materialize ordered system options'
printf 'updated file prompt\n' >"$override_file"
derived="$tmp/derived.jsonl"
zsh -f "$entry" run --session-create --session-from "$override" --session-out "$derived" || \
  fail 'create did not reuse the stored system text'
jq -se --slurpfile source "$override" '.[0].profile == $source[0].profile' \
  "$derived" >/dev/null || fail 'derived create reread the system files'
zsh -f "$entry" run --session-create --session-from "$override" \
  --system '{"text":"extra"}' >/dev/null 2>&1 &&
  fail 'derived create accepted a system option'

# Empty prompts leave no system text.
typeset empty_file="$tmp/empty.md" empty_session="$tmp/empty.jsonl"
printf '\n\n' >"$empty_file"
sf_test_profile empty "{\"system\": [{\"text\": \"\"}, \"$empty_file\"]}"
zsh -f "$entry" run --session-create --session-out "$empty_session" -p empty ||
  fail 'empty system prompts failed'
jq -se '.[0].profile.system == []' "$empty_session" >/dev/null ||
  fail 'empty prompts left system text'

# Reject unreadable system components.
typeset missing="$tmp/missing.jsonl"
sf_test_profile missing-system "{\"system\": [\"$tmp/absent.md\"]}"
zsh -f "$entry" run --session-create --session-out "$missing" -p missing-system >/dev/null 2>&1 &&
  fail 'a missing system component created a session'
[[ ! -e $missing ]] || fail 'create left a transcript for a missing component'
zsh -f "$entry" run --session-create --session-out "$missing" \
  --system "$tmp/absent.md" >/dev/null 2>&1 &&
  fail 'create accepted a missing system option file'
[[ ! -e $missing ]] || fail 'missing system option left a transcript'

# Reject system input that cannot survive shell transport intact.
typeset binary="$tmp/binary.jsonl" binary_file="$tmp/binary.md"
printf 'before\0after\n' >"$binary_file"
zsh -f "$entry" run --session-create --session-out "$binary" \
  --system "$binary_file" >/dev/null 2>&1 &&
  fail 'create accepted system content containing NUL bytes'
[[ ! -e $binary ]] || fail 'binary system input left a transcript'

# A failed later startup retains and streams the completed prefix.
typeset events="$tmp/events.jsonl" first="$tmp/first-hook"
sf_test_hook "$first" \
  '{"on":"session_start","user_text":"${output.stderr}"}' <<'ZSH'
#!/usr/bin/env zsh
[[ -f $SHELLFISH_SESSION ]] || exit 2
jq -se 'map(.type) == ["_session_load","session"]' \
  "$SF_TEST_EVENTS" >/dev/null || exit 3
print -r -u3 -- '{"state_update":[{"name":"startup/stream","value":true}]}'
print -rn -- 'startup context'
print -rn -u2 -- 'startup display'
ZSH
sf_test_profile stream \
  "{\"system\": [\"source.md\"], \"hooks\": [\"$first\", \"$hook\"]}"
failed="$tmp/later-failed.jsonl"
SF_TEST_EVENTS="$events" zsh -f "$entry" run --jsonl --session-create \
  --session-out "$failed" -p stream >"$events" 2>"$hook_error" &&
  fail 'a later startup failure succeeded'
[[ -f $failed && $(<"$hook_error") == *'session_start hook failed with status 9:'* ]] ||
  fail 'failed startup did not retain its session and diagnostic'
jq -se '
  map(.type) == ["_session_load","session","state_update","hook_result"] and
  .[-1].user_text == "startup display" and .[-1].model_text == "startup context"
' "$events" >/dev/null || fail 'a failed creation lost its durable prefix'
jq -se 'map(.type) == ["session","state_update","hook_result"]' \
  "$failed" >/dev/null || fail 'a failed creation lost its durable prefix'

# Cancel running startup scripts.
typeset slow="$tmp/slow-hook" cancelled="$tmp/cancelled.jsonl"
export SLOW_MARKER="$tmp/slow-active" SLOW_RELEASE="$tmp/slow-release"
export SLOW_EXIT_MARKER="$tmp/slow-exit"
sf_test_hook "$slow" '{"on":"session_start"}' <<'ZSH'
#!/usr/bin/env zsh
: >"$SLOW_MARKER"
# Release detects scripts that survive cancellation.
while [[ ! -e $SLOW_RELEASE ]]; do
  sleep 0.05
done
: >"$SLOW_EXIT_MARKER"
ZSH
sf_test_profile slow \
  "{\"system\": [\"source.md\"], \"hooks\": [\"$slow\"]}"
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
jq -se 'map(.type) == ["_session_load","session"]' \
  "$events" >/dev/null || fail 'cancelled creation lost its durable prefix'
jq -se 'map(.type) == ["session"]' "$cancelled" >/dev/null ||
  fail 'cancelled creation lost its transcript prefix'
[[ -s $hook_error ]] || fail 'cancelled creation omitted stderr diagnostic'

# Moving a home preserves its frozen home-relative references.
typeset old_home="$tmp/original-home" new_home="$tmp/moved-home"
typeset old_project="$old_home/project" new_project="$new_home/project"
mkdir -p "$old_project" "$old_home/.shellfish/profiles" "$old_home/.shellfish/models"
print -r -- 'original prompt' >"$old_project/prompt.md"
sf_test_hook "$old_project/hook" '{"on":"user_prompt_submit"}' <<'ZSH'
#!/usr/bin/env zsh
pwd -P >"$PWD/hook-cwd"
ZSH
cp "$SF_TEST_CONFIG/models/default.jsonc" "$old_home/.shellfish/models/default.jsonc"
cat >"$old_home/.shellfish/profiles/default.jsonc" <<EOF
{
  "system": ["$old_project/prompt.md"],
  "hooks": ["$old_project/hook"]
}
EOF
(
  builtin cd -- "$old_project"
  HOME="$old_home" SHELLFISH_DIR="$old_home/.shellfish" zsh -f "$entry" run \
    --session-create --session-out "$PWD/session.jsonl"
) || fail 'portable session creation failed'
jq -e 'select(.type == "session") |
  .cwd == "~/project" and .profile.system == [{text:"original prompt"}] and
  .profile.hooks == ["~/project/hook"]
' "$old_project/session.jsonl" >/dev/null || fail 'session did not store portable paths'
mv -- "$old_home" "$new_home"
(
  builtin cd -- "$new_project"
  HOME="$new_home" SHELLFISH_DIR="$new_home/.shellfish" SF_TEST_PROVIDER_DELAY=0 zsh -f "$entry" run \
    --session "$PWD/session.jsonl" 'plain answer' >"$tmp/relocated-answer"
) || fail 'relocated session turn failed'
assert_equal 'plain answer' "$(<"$tmp/relocated-answer")"
assert_equal "${new_project:A}" "$(<"$new_project/hook-cwd")" \
  'relocated hook ran outside the project'
print -r -- ok
