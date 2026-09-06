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

# --session-from names the session whose header and durable system record are copied.
print -r -- 'changed configured system' >"$tmp/system/source.md"
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$created"
reused=$(zsh -f "$entry" create --session-from "$created") || fail 'sourced create failed'
jq -e -s --slurpfile source "$created" '
  length == 2 and .[1] == {type:"system",content:"initial system"} and
  (.[0] | del(.created)) == ($source[0] | del(.created))
' "$reused" >/dev/null || fail 'create did not copy the source header and system record'

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
# Session state stays a disposable cache even when creation fails.
typeset hook="$tmp/failing-hook" marker="$tmp/state-marker" hook_config="$tmp/hook.jsonc"
cat >"$hook" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == session_start && -d $SHELLFISH_SESSION_STATE && -z ${SHELLFISH_TURN_STATE-} ]] || exit 2
print -r -- "$SHELLFISH_SESSION_STATE" >"$SF_TEST_STATE_MARKER"
print -u2 -r -- 'startup detail'
exit 9
ZSH
chmod +x "$hook"
jq --arg hook "$hook" '.harnesses.machine.session_start=[$hook]' "$config" >"$hook_config"
typeset failed="$tmp/failed.jsonl" hook_error="$tmp/hook-error"
SF_TEST_STATE_MARKER="$marker" zsh -f "$entry" create --session-out "$failed" \
  --config "$hook_config" >/dev/null 2>"$hook_error" &&
  fail 'a failing session_start script created a session'
[[ $(<"$hook_error") == *"hook script failed with status 9: ${hook:A}: startup detail"* ]] ||
  fail 'create hid the session_start failure'
[[ ! -e $failed ]] || fail 'create left a transcript behind'
[[ -d $(<"$marker") && $(<"$marker") == */sessions/failed ]] ||
  fail 'create did not prepare session state'

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
  (.[0].profile | has("system") | not) and
  .[1] == {type:"system",content:"inline\nprompt\n\nfile prompt\n\nlast prompt"}
' "$override" >/dev/null || fail 'create did not materialize ordered system overrides'
printf 'updated file prompt\n' >"$override_file"
jq -c 'if .type == "system" then .content += "\n\n" else . end' "$override" \
  >"$tmp/stored-system.jsonl"
mv "$tmp/stored-system.jsonl" "$override"
derived=$(zsh -f "$entry" create --session-from "$override") || \
  fail 'create did not copy the durable system record'
jq -se '
  length == 2 and
  .[1] == {type:"system",content:"inline\nprompt\n\nfile prompt\n\nlast prompt\n\n"}
' "$derived" >/dev/null || fail 'create did not preserve the durable system record'
typeset derived_override="$tmp/derived-override.jsonl"
zsh -f "$entry" create --session-out "$derived_override" --session-from "$override" \
  --system '--session-out' >/dev/null || fail 'derived create rejected option-looking system text'
jq -se 'length == 2 and .[1] == {type:"system",content:"--session-out"}' \
  "$derived_override" >/dev/null || fail 'derived create did not replace the copied system record'

# Empty overrides clear configured and copied prompts without adding separators.
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

# Startup previews reach hooks' observers before the initial prefix is written.
typeset events="$tmp/events.jsonl" streamed="$tmp/streamed.jsonl"
typeset first="$tmp/first-hook" silent="$tmp/silent-hook" stream_config="$tmp/stream.jsonc"
cat >"$first" <<'ZSH'
#!/usr/bin/env zsh
[[ ! -e $SHELLFISH_SESSION ]] || exit 2
jq -se 'length == 2 and .[0].type == "_session_prepare" and
  .[1].type == "_notice" and .[1].complete == false and .[1].text == ""' \
  "$SF_TEST_EVENTS" >/dev/null || exit 3
print -r -- 'startup context'
printf '%*s' "${SF_TEST_CONTEXT_BYTES:-0}" ''
print -u2 -r -- 'startup display'
ZSH
cat >"$silent" <<'ZSH'
#!/usr/bin/env zsh
[[ ! -e $SHELLFISH_SESSION ]] || exit 2
jq -se '.[-2].complete == true and .[-1].complete == false and .[-1].text == ""' \
  "$SF_TEST_EVENTS" >/dev/null || exit 3
ZSH
chmod +x "$first" "$silent"
jq --arg first "$first" --arg silent "$silent" \
  '.harnesses.machine.session_start=[$first,$silent]' "$config" >"$stream_config"
SF_TEST_EVENTS="$events" zsh -f "$entry" create --jsonl --config "$stream_config" \
  --session-out "$streamed" >"$events" 2>"$hook_error" || fail 'streamed creation failed'
[[ ! -s $hook_error ]] || fail 'streamed display leaked to stderr'
jq -se --arg path "$streamed" --arg first "${first:A}" --arg silent "${silent:A}" \
  --slurpfile session "$streamed" '
  map(.type) == ["_session_prepare","_notice","_notice","_notice",
    "_notice","_notice","_session_created"] and
  .[0].path == $path and .[0].records == $session[:2] and
  (.[0].presentation | keys == ["theme","tui"]) and
  .[1] == {type:"_notice",level:"info",source:"session_start",title:$first,
    text:"",complete:false} and
  .[2].text == "startup display\n" and .[2].complete == false and
  .[3].text == "startup display\n" and .[3].complete == true and
  .[3].context == $session[2] and
  .[4] == {type:"_notice",level:"info",source:"session_start",title:$silent,
    text:"",complete:false} and
  .[5] == {type:"_notice",level:"info",source:"session_start",title:$silent,
    text:"",complete:true} and
  .[6] == {type:"_session_created",path:$path} and
  $session[2] == {type:"context",hook:"session_start",script:"first-hook",content:"startup context\n"} and
  ($session | length == 3)
' "$events" >/dev/null || fail 'invalid creation event sequence or transcript'

# Context previews use the capture budget, not the operating system's argv limit.
typeset large="$tmp/large.jsonl" large_config="$tmp/large.jsonc"
jq '.harnesses.machine.max_capture_bytes=400000' "$stream_config" >"$large_config"
SF_TEST_EVENTS="$events" SF_TEST_CONTEXT_BYTES=300000 zsh -f "$entry" create --jsonl \
  --session-out "$large" --config "$large_config" >"$events" 2>"$hook_error" ||
  fail 'large context preview failed'
jq -se --slurpfile session "$large" '.[3].context == $session[2] and
  (.[3].context.content | length == 300016)' "$events" >/dev/null ||
  fail 'large context preview was truncated'

# Empty startup has no hook events, including when the system is empty.
zsh -f "$entry" create --jsonl --config "$config" --system '' >"$events"
jq -se 'map(.type) == ["_session_prepare","_session_created"] and
  (.[0].records | length == 1)' "$events" >/dev/null || fail 'invalid empty startup stream'

# Failure leaves only previews, never a durable session or completion signal.
SF_TEST_STATE_MARKER="$marker" zsh -f "$entry" create --jsonl --session-out "$failed" \
  --config "$hook_config" >"$events" 2>"$hook_error" && fail 'streamed failure succeeded'
[[ ! -e $failed && $(<"$hook_error") == *'hook script failed with status 9:'* ]]
jq -se 'map(.type) == ["_session_prepare","_notice","_notice","_notice"] and
  all(.[]; has("context") | not)' \
  "$events" >/dev/null || fail 'failed creation emitted completion'

# A later failure does not make an earlier context preview durable.
jq --arg first "$first" '.harnesses.machine.session_start |= [$first] + .' \
  "$hook_config" >"$stream_config"
SF_TEST_EVENTS="$events" SF_TEST_STATE_MARKER="$marker" zsh -f "$entry" create --jsonl \
  --session-out "$failed" --config "$stream_config" >"$events" 2>"$hook_error" &&
  fail 'a later startup failure succeeded'
[[ ! -e $failed && $(<"$hook_error") == *'hook script failed with status 9:'* ]]
jq -se 'any(.context.content == "startup context\n") and
  all(.[]; .type != "_session_created")' "$events" >/dev/null ||
  fail 'later failure lost the preview or reported creation'

print -r -- ok
