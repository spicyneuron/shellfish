#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp create-command
mkdir -p "$tmp/home" "$tmp/system"
print -r -- 'initial system' >"$tmp/system/source.md"
export HOME="${tmp:A}/home"
export XDG_STATE_HOME="$tmp/state"
unset XDG_CONFIG_HOME

typeset config="$tmp/shellfish.jsonc"
cat >"$config" <<EOF
{
  "default_profile": "machine",
  "backends": {"fixture": {"adapter": "$ROOT/tests/fixtures/backend"}},
  "harnesses": {
    "machine": {
      "tools": [], "session_start": [], "user_prompt_submit": [],
      "permission_request": [], "pre_tool_use": [], "post_tool_use": [], "stop": []
    }
  },
  "profiles": {
    "machine": {
      "backend": "fixture", "harness": "machine", "system": ["source.md"],
      "request": {"model": "test-model"}
    }
  }
}
EOF

typeset entry="$ROOT/bin/shellfish"
typeset created reused explicit

# Create a complete idle session.
created=$(zsh -f "$entry" create --config "$config") || fail 'create failed'
[[ -f $created && $created == /* ]] || fail 'create did not print an absolute session path'
jq -es 'length == 2 and .[0].type == "session" and
  .[1] == {type:"system",content:"initial system"}' \
  "$created" >/dev/null || fail 'create did not write the initial session prefix'

# Select an explicit destination.
explicit="$tmp/explicit.jsonl"
assert_equal "$explicit" \
  "$(zsh -f "$entry" create --session-out "$explicit" --config "$config")" \
  'create ignored --session-out'
jq -es 'length == 2' "$explicit" >/dev/null || fail 'create did not populate --session-out'

# Freeze forwarded sandbox grants.
typeset granted="$tmp/granted.jsonl"
zsh -f "$entry" create --session-out "$granted" --config "$config" \
  --sandbox-read "${tmp:A}/system" --sandbox-write "${tmp:A}/home" >/dev/null || \
  fail 'create rejected forwarded sandbox grants'
jq -e --arg read "${tmp:A}/system" --arg write "${tmp:A}/home" '
  select(.type == "session") |
  (.harness.sandbox_read_paths | index($read)) != null and
  (.harness.sandbox_write_paths | index($write)) != null
' "$granted" >/dev/null || fail 'create did not store forwarded sandbox grants'

# Derived sessions reuse runtime and reread system paths.
print -r -- 'changed configured system' >"$tmp/system/source.md"
print -r -- '{"type":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$created"
reused=$(zsh -f "$entry" create --session-from "$created") || fail 'sourced create failed'
jq -e -s --slurpfile source "$created" '
  length == 2 and .[1] == {type:"system",content:"changed configured system"} and
  (.[0] | del(.created)) == ($source[0] | del(.created))
' "$reused" >/dev/null || fail 'create did not reuse the stored runtime'

# Reject a missing source.
zsh -f "$entry" create --session-from "$tmp/absent.jsonl" >/dev/null 2>&1 &&
  fail 'create accepted a missing source'

# Preserve occupied destinations.
zsh -f "$entry" create --session-out "$explicit" --config "$config" >/dev/null 2>&1 &&
  fail 'create overwrote an existing session'

# Reject overrides for stored sessions.
zsh -f "$entry" create --session-from "$created" --model other >/dev/null 2>&1 &&
  fail 'create accepted a runtime override with --session-from'

# Clean up failed startup hooks.
typeset hook="$tmp/failing-hook" hook_config="$tmp/hook.jsonc"
mkdir "$hook"
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == session_start && -z ${SHELLFISH_TURN_STATE-} ]] || exit 2
print -u2 -r -- 'startup detail'
exit 9
ZSH
chmod +x "$hook/run"
jq --arg hook "$hook" '.harnesses.machine.session_start=[$hook]' "$config" >"$hook_config"
typeset failed="$tmp/failed.jsonl" hook_error="$tmp/hook-error"
zsh -f "$entry" create --session-out "$failed" \
  --config "$hook_config" >/dev/null 2>"$hook_error" &&
  fail 'a failing session_start script created a session'
[[ $(<"$hook_error") == *"hook script failed with status 9: ${hook:A}/run: startup detail"* ]] ||
  fail 'create hid the session_start failure'
[[ ! -e $failed ]] || fail 'create left a transcript behind'

# Join system components in order.
typeset joined="$tmp/joined.jsonl" joined_config="$tmp/joined.jsonc"
printf 'first prompt\n\n\n' >"$tmp/system/first.md"
printf 'second prompt\n' >"$tmp/system/second.md"
jq '.profiles.machine.system=["first.md","second.md"]' "$config" >"$joined_config"
zsh -f "$entry" create --session-out "$joined" --config "$joined_config" >/dev/null ||
  fail 'multi-component create failed'
jq -se 'length == 2 and .[1] == {type:"system",content:"first prompt\n\nsecond prompt"}' \
  "$joined" >/dev/null || fail 'create did not join the system components'

# Preserve mixed system override order.
typeset override="$tmp/override.jsonl" override_file="$tmp/override.md" derived
printf 'file prompt\n' >"$override_file"
zsh -f "$entry" create --session-out "$override" --config "$config" \
  --system $'inline\nprompt\n\n' --system-file "$override_file" --system 'last prompt' \
  >/dev/null || fail 'create rejected system overrides'
jq -se '
  length == 2 and
  (.[0].profile.system | length) == 1 and
  .[1] == {type:"system",content:"inline\nprompt\n\nfile prompt\n\nlast prompt"}
' "$override" >/dev/null || fail 'create did not materialize ordered system overrides'
printf 'updated file prompt\n' >"$override_file"
jq -c 'if .type == "system" then .content += "\n\n" else . end' "$override" \
  >"$tmp/stored-system.jsonl"
mv "$tmp/stored-system.jsonl" "$override"
derived=$(zsh -f "$entry" create --session-from "$override") || \
  fail 'create did not reuse the stored system paths'
jq -se '
  length == 2 and
  .[1] == {type:"system",content:"changed configured system"}
' "$derived" >/dev/null || fail 'create did not rematerialize the stored system paths'
typeset derived_override="$tmp/derived-override.jsonl"
zsh -f "$entry" create --session-out "$derived_override" --session-from "$override" \
  --system '--session-out' >/dev/null || fail 'derived create rejected option-looking system text'
jq -se 'length == 2 and .[1] == {type:"system",content:"--session-out"}' \
  "$derived_override" >/dev/null || fail 'derived create did not apply the system override'

# Clear prompts with empty overrides.
typeset empty_file="$tmp/empty.md" empty_session
printf '\n\n' >"$empty_file"
for source in --config --session-from; do
  typeset source_path=$config
  [[ $source != --session-from ]] || source_path=$override
  empty_session=$(zsh -f "$entry" create "$source" "$source_path" \
    --system '' --system-file "$empty_file") || fail 'empty system override failed'
  jq -se 'length == 1' "$empty_session" >/dev/null || fail 'empty override retained a system record'
done

# Reject unreadable system components.
typeset missing="$tmp/missing.jsonl" missing_config="$tmp/missing.jsonc"
jq --arg path "$tmp/absent.md" '.profiles.machine.system=[$path]' "$config" >"$missing_config"
zsh -f "$entry" create --session-out "$missing" --config "$missing_config" >/dev/null 2>&1 &&
  fail 'a missing system component created a session'
[[ ! -e $missing ]] || fail 'create left a transcript for a missing component'
zsh -f "$entry" create --session-out "$missing" --config "$config" \
  --system-file "$tmp/absent.md" >/dev/null 2>&1 &&
  fail 'create accepted a missing system override file'
[[ ! -e $missing ]] || fail 'missing system override left a transcript'

# Reject system input that cannot survive shell transport intact.
typeset binary="$tmp/binary.jsonl" binary_file="$tmp/binary.md"
printf 'before\0after\n' >"$binary_file"
zsh -f "$entry" create --session-out "$binary" --config "$config" \
  --system-file "$binary_file" >/dev/null 2>&1 &&
  fail 'create accepted system content containing NUL bytes'
[[ ! -e $binary ]] || fail 'binary system input left a transcript'

# Startup records are durable before the next component runs.
typeset events="$tmp/events.jsonl" streamed="$tmp/streamed.jsonl"
typeset first="$tmp/first-hook" silent="$tmp/silent-hook" stream_config="$tmp/stream.jsonc"
mkdir "$first" "$silent"
cat >"$first/run" <<'ZSH'
#!/usr/bin/env zsh
[[ -f $SHELLFISH_SESSION ]] || exit 2
jq -se 'map(.type) == ["_session_prepare","_hook_activity"]' \
  "$SF_TEST_EVENTS" >/dev/null || exit 3
print -r -- 'startup context'
printf '%*s' "${SF_TEST_CONTEXT_BYTES:-0}" ''
print -rn -u3 -- '{"state":[{"name":"startup/stream","value":true}]}'
print -u2 -r -- 'startup display'
ZSH
cat >"$silent/run" <<'ZSH'
#!/usr/bin/env zsh
[[ -f $SHELLFISH_SESSION ]] || exit 2
jq -se 'map(.type) == ["_session_prepare","_hook_activity","state","hook_result",
  "_hook_activity"]' "$SF_TEST_EVENTS" >/dev/null || exit 3
jq -se '.[-2] == {type:"state",name:"startup/stream",value:true} and
  .[-1].type == "hook_result" and (.[-1].executable | endswith("/first-hook/run"))' \
  "$SHELLFISH_SESSION" >/dev/null || exit 4
ZSH
print -r -- '{}' >"$first/manifest.json"
chmod +x "$first/run" "$silent/run"
jq --arg first "$first" --arg silent "$silent" \
  '.harnesses.machine.session_start=[$first,$silent]' "$config" >"$stream_config"
SF_TEST_EVENTS="$events" zsh -f "$entry" create --jsonl --config "$stream_config" \
  --session-out "$streamed" >"$events" 2>"$hook_error" || fail 'streamed creation failed'
[[ ! -s $hook_error ]] || fail 'streamed display leaked to stderr'
jq -se --arg path "$streamed" --arg first "${first:A}/run" --arg silent "${silent:A}/run" \
  --slurpfile session "$streamed" '
  map(.type) == ["_session_prepare","_hook_activity","state","hook_result",
    "_hook_activity","_session_created"] and
  .[0] == {type:"_session_prepare",path:$path,records:$session[:2]} and
  (.[1] | del(.id)) == {type:"_hook_activity",hook:"session_start",name:"first-hook",
    executable:$first,input:""} and
  .[2] == $session[2] and .[2] ==
    {type:"state",name:"startup/stream",value:true} and
  .[3] == $session[3] and
  .[3].type == "hook_result" and .[3].lifecycle == "session_start" and
  .[3].name == "first-hook" and .[3].executable == $first and .[3].input == "" and
  .[3].exit_code == 0 and
  (.[3].user_text | contains("startup context")) and
  (.[3].user_text | contains("startup display")) and
  (.[3].model_text | contains("startup context\n")) and
  .[1].id == .[3].id and
  # A hook that captured nothing records no result.
  (.[4] | del(.id)) == {type:"_hook_activity",hook:"session_start",name:"silent-hook",
    executable:$silent,input:""} and
  .[5] == {type:"_session_created",path:$path} and
  ($session | length == 4)
' "$events" >/dev/null || fail 'invalid creation event sequence or transcript'

# Later failures preserve completed records.
jq --arg first "$first" '.harnesses.machine.session_start |= [$first] + .' \
  "$hook_config" >"$stream_config"
SF_TEST_EVENTS="$events" zsh -f "$entry" create --jsonl \
  --session-out "$failed" --config "$stream_config" >"$events" 2>"$hook_error" &&
  fail 'a later startup failure succeeded'
[[ ! -e $failed && $(<"$hook_error") == *'hook script failed with status 9:'* ]]
jq -se '
  map(.type) == ["_session_prepare","_hook_activity","state","hook_result",
    "_hook_activity"] and
  all(.[]; .type != "_session_created")
' "$events" >/dev/null || fail 'later failure lost the completed hook prefix'

# Cancel running startup scripts.
typeset slow="$tmp/slow-hook" slow_config="$tmp/slow.jsonc" cancelled="$tmp/cancelled.jsonl"
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
jq --arg slow "$slow" '.harnesses.machine.session_start=[$slow]' "$config" >"$slow_config"
zsh -f "$entry" create --jsonl --config "$slow_config" --session-out "$cancelled" \
  >"$events" 2>"$hook_error" &
integer create_pid=$! cancel_status=0 waited=0
while (( waited++ < 50 )) && [[ ! -e $SLOW_MARKER ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'session_start hook script did not start'
kill -USR1 "$create_pid"
wait "$create_pid" || cancel_status=$?
(( cancel_status == 130 )) || fail 'cancelled creation did not report cancellation'
[[ ! -e $cancelled ]] || fail 'cancelled creation wrote a session'
: >"$SLOW_RELEASE"
sleep 0.3
[[ ! -e $SLOW_EXIT_MARKER ]] || fail 'cancelled session_start hook script ran to completion'
jq -se '
  all(.[]; .type != "_session_created")
' "$events" >/dev/null || fail 'cancelled creation did not emit its final error'
[[ -s $hook_error ]] || fail 'cancelled creation omitted stderr diagnostic'

print -r -- ok
