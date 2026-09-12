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

# Current configuration produces a complete idle session prefix.
created=$(zsh -f "$entry" create --config "$config") || fail 'create failed'
[[ -f $created && $created == /* ]] || fail 'create did not print an absolute session path'
jq -es 'length == 2 and .[0].type == "session" and
  .[1] == {type:"system",content:"initial system"}' \
  "$created" >/dev/null || fail 'create did not write the initial session prefix'

# --session-out selects the destination; the runtime still comes from configuration.
explicit="$tmp/explicit.jsonl"
assert_equal "$explicit" \
  "$(zsh -f "$entry" create --session-out "$explicit" --config "$config")" \
  'create ignored --session-out'
jq -es 'length == 2' "$explicit" >/dev/null || fail 'create did not populate --session-out'

# Sandbox grants are forwarded to config unread and frozen into the header.
typeset granted="$tmp/granted.jsonl"
zsh -f "$entry" create --session-out "$granted" --config "$config" \
  --sandbox-read "${tmp:A}/system" --sandbox-write "${tmp:A}/home" >/dev/null || \
  fail 'create rejected forwarded sandbox grants'
jq -e --arg read "${tmp:A}/system" --arg write "${tmp:A}/home" '
  select(.type == "session") |
  (.harness.sandbox_read_paths | index($read)) != null and
  (.harness.sandbox_write_paths | index($write)) != null
' "$granted" >/dev/null || fail 'create did not store forwarded sandbox grants'

# --session-from reuses the stored runtime and rematerializes its system paths.
print -r -- 'changed configured system' >"$tmp/system/source.md"
print -r -- '{"type":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$created"
reused=$(zsh -f "$entry" create --session-from "$created") || fail 'sourced create failed'
jq -e -s --slurpfile source "$created" '
  length == 2 and .[1] == {type:"system",content:"changed configured system"} and
  (.[0] | del(.created)) == ($source[0] | del(.created))
' "$reused" >/dev/null || fail 'create did not reuse the stored runtime'

# Source paths must be present, nonempty, and specified once.
zsh -f "$entry" create --session-from "$tmp/absent.jsonl" >/dev/null 2>&1 &&
  fail 'create accepted a missing source'
zsh -f "$entry" create --session-from '' >/dev/null 2>&1 &&
  fail 'create accepted an empty source'
zsh -f "$entry" create --session-from >/dev/null 2>&1 &&
  fail 'create accepted a bare source option'
zsh -f "$entry" create --session-from "$created" --session-from "$created" >/dev/null 2>&1 &&
  fail 'create accepted repeated sources'

# An occupied destination is never overwritten.
zsh -f "$entry" create --session-out "$explicit" --config "$config" >/dev/null 2>&1 &&
  fail 'create overwrote an existing session'
typeset empty="$tmp/empty.jsonl"
: >"$empty"
zsh -f "$entry" create --session-out "$empty" --config "$config" >/dev/null 2>&1 &&
  fail 'create accepted an existing empty destination'
[[ -f $empty && ! -s $empty ]] || fail 'create removed an existing empty destination'

# Runtime overrides against an existing session stay rejected by config.
zsh -f "$entry" create --session-from "$created" --model other >/dev/null 2>&1 &&
  fail 'create accepted a runtime override with --session-from'

# Options create does not own are forwarded unparsed.
zsh -f "$entry" create --config "$tmp/missing.jsonc" >/dev/null 2>&1 &&
  fail 'create accepted an unreadable config'
zsh -f "$entry" create --session-out >/dev/null 2>&1 && fail 'create accepted a bare --session-out'
zsh -f "$entry" create --session-out "$tmp/a.jsonl" --session-out "$tmp/b.jsonl" >/dev/null 2>&1 &&
  fail 'create accepted a repeated --session-out'

# A failing session_start script leaves no transcript and reports its detail.
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

# System components concatenate into one ordered record.
typeset joined="$tmp/joined.jsonl" joined_config="$tmp/joined.jsonc"
printf 'first prompt\n\n\n' >"$tmp/system/first.md"
printf 'second prompt\n' >"$tmp/system/second.md"
jq '.profiles.machine.system=["first.md","second.md"]' "$config" >"$joined_config"
zsh -f "$entry" create --session-out "$joined" --config "$joined_config" >/dev/null ||
  fail 'multi-component create failed'
jq -se 'length == 2 and .[1] == {type:"system",content:"first prompt\n\nsecond prompt"}' \
  "$joined" >/dev/null || fail 'create did not join the system components'

# Command-line system inputs replace the profile list and retain mixed order.
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

# Empty overrides clear configured prompts without adding separators.
typeset empty_file="$tmp/empty.md" empty_session
printf '\n\n' >"$empty_file"
for source in --config --session-from; do
  typeset source_path=$config
  [[ $source != --session-from ]] || source_path=$override
  empty_session=$(zsh -f "$entry" create "$source" "$source_path" \
    --system '' --system-file "$empty_file") || fail 'empty system override failed'
  jq -se 'length == 1' "$empty_session" >/dev/null || fail 'empty override retained a system record'
done

# An unreadable component fails without creating a transcript.
typeset missing="$tmp/missing.jsonl" missing_config="$tmp/missing.jsonc"
jq --arg path "$tmp/absent.md" '.profiles.machine.system=[$path]' "$config" >"$missing_config"
zsh -f "$entry" create --session-out "$missing" --config "$missing_config" >/dev/null 2>&1 &&
  fail 'a missing system component created a session'
[[ ! -e $missing ]] || fail 'create left a transcript for a missing component'
zsh -f "$entry" create --session-out "$missing" --config "$config" \
  --system-file "$tmp/absent.md" >/dev/null 2>&1 &&
  fail 'create accepted a missing system override file'
[[ ! -e $missing ]] || fail 'missing system override left a transcript'

# Configured and override files are read by create, including binary validation.
typeset binary="$tmp/binary.jsonl" binary_file="$tmp/binary.md"
printf 'before\0after\n' >"$binary_file"
for source in configured override; do
  typeset -a binary_args=( --session-out "$binary" --config "$config" )
  if [[ $source == configured ]]; then
    jq --arg file "$binary_file" '.profiles.machine.system=[$file]' \
      "$config" >"$tmp/binary-config.jsonc"
    binary_args=( --session-out "$binary" --config "$tmp/binary-config.jsonc" )
  else
    binary_args+=( --system-file "$binary_file" )
  fi
  typeset binary_error=''
  binary_error=$(zsh -f "$entry" create "${binary_args[@]}" 2>&1) &&
    fail 'create accepted a system file containing NUL bytes'
  [[ $binary_error == *'system content must not contain NUL bytes'* ]] || fail "$binary_error"
  [[ ! -e $binary ]] || fail 'binary system input left a transcript'
done

# Startup components stream configured activity around immediate durable records.
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
jq -se 'map(.type) == ["_session_prepare","_hook_activity","state","hook_result"]' \
  "$SF_TEST_EVENTS" >/dev/null || exit 3
jq -se '.[-2] == {type:"state",name:"startup/stream",value:true} and
  .[-1].type == "hook_result" and .[-1].script == "first-hook"' \
  "$SHELLFISH_SESSION" >/dev/null || exit 4
ZSH
print -r -- '{"display":"Starting up"}' >"$first/manifest.json"
chmod +x "$first/run" "$silent/run"
jq --arg first "$first" --arg silent "$silent" \
  '.harnesses.machine.session_start=[$first,$silent]' "$config" >"$stream_config"
SF_TEST_EVENTS="$events" zsh -f "$entry" create --jsonl --config "$stream_config" \
  --session-out "$streamed" >"$events" 2>"$hook_error" || fail 'streamed creation failed'
[[ ! -s $hook_error ]] || fail 'streamed display leaked to stderr'
jq -se --arg path "$streamed" \
  --slurpfile session "$streamed" '
  map(.type) == ["_session_prepare","_hook_activity","state","hook_result",
    "_session_created"] and
  .[0] == {type:"_session_prepare",path:$path,records:$session[:2]} and
  .[1] == {type:"_hook_activity",hook:"session_start",script:"first-hook",
    text:"Starting up"} and
  .[2] == $session[2] and .[2] ==
    {type:"state",name:"startup/stream",value:true} and
  .[3] == $session[3] and .[3] ==
    {type:"hook_result",hook:"session_start",script:"first-hook",
      model_context:"startup context\n",user_context:"startup display\n"} and
  .[4] == {type:"_session_created",path:$path} and
  ($session | length == 4)
' "$events" >/dev/null || fail 'invalid creation event sequence or transcript'

# Startup context uses the capture budget, not the operating system's argv limit.
typeset large="$tmp/large.jsonl" large_config="$tmp/large.jsonc"
jq '.harnesses.machine.max_capture_bytes=400000' "$stream_config" >"$large_config"
SF_TEST_EVENTS="$events" SF_TEST_CONTEXT_BYTES=300000 zsh -f "$entry" create --jsonl \
  --session-out "$large" --config "$large_config" >"$events" 2>"$hook_error" ||
  fail 'large startup context failed'
jq -se --slurpfile session "$large" '.[3] == $session[3] and
  (.[3].model_context | length == 300016)' "$events" >/dev/null ||
  fail 'large startup context was truncated'

# Empty startup has no hook events, including when the system is empty.
zsh -f "$entry" create --jsonl --config "$config" --system '' >"$events"
jq -se 'map(.type) == ["_session_prepare","_session_created"] and
  (.[0].records | length == 1)' "$events" >/dev/null || fail 'invalid empty startup stream'

# Failure removes the initial session and reports through stderr.
SF_TEST_STATE_MARKER="$marker" zsh -f "$entry" create --jsonl --session-out "$failed" \
  --config "$hook_config" >"$events" 2>"$hook_error" && fail 'streamed failure succeeded'
[[ ! -e $failed && $(<"$hook_error") == *'hook script failed with status 9:'* ]]
jq -se 'map(.type) == ["_session_prepare"]' \
  "$events" >/dev/null || fail 'failed creation emitted completion'

# A later failure leaves the earlier component's emitted records as a valid prefix.
jq --arg first "$first" '.harnesses.machine.session_start |= [$first] + .' \
  "$hook_config" >"$stream_config"
SF_TEST_EVENTS="$events" SF_TEST_STATE_MARKER="$marker" zsh -f "$entry" create --jsonl \
  --session-out "$failed" --config "$stream_config" >"$events" 2>"$hook_error" &&
  fail 'a later startup failure succeeded'
[[ ! -e $failed && $(<"$hook_error") == *'hook script failed with status 9:'* ]]
jq -se '
  map(.type) == ["_session_prepare","_hook_activity","state","hook_result"] and
  all(.[]; .type != "_session_created")
' "$events" >/dev/null || fail 'later failure lost the completed hook prefix'

# The client's cancellation signal stops the running script and saves nothing.
typeset slow="$tmp/slow-hook" slow_config="$tmp/slow.jsonc" cancelled="$tmp/cancelled.jsonl"
export SLOW_MARKER="$tmp/slow-active" SLOW_RELEASE="$tmp/slow-release"
export SLOW_EXIT_MARKER="$tmp/slow-exit"
mkdir "$slow"
cat >"$slow/run" <<'ZSH'
#!/usr/bin/env zsh
: >"$SLOW_MARKER"
# Released rather than timed: a sleeping script looks stopped either way.
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
