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

# --path selects the destination; the runtime still comes from configuration.
explicit="$tmp/explicit.jsonl"
assert_equal "$explicit" \
  "$(zsh -f "$entry" create --path "$explicit" --config "$config")" \
  'create ignored --path'
jq -es 'length == 2' "$explicit" >/dev/null || fail 'create did not populate --path'

# Sandbox grants are forwarded to config unread and frozen into the header.
typeset granted="$tmp/granted.jsonl"
zsh -f "$entry" create --path "$granted" --config "$config" \
  --sandbox-read "${tmp:A}/system" --sandbox-write "${tmp:A}/home" >/dev/null || \
  fail 'create rejected forwarded sandbox grants'
jq -e --arg read "${tmp:A}/system" --arg write "${tmp:A}/home" '
  select(.type == "session") |
  (.harness.sandbox_read_paths | index($read)) != null and
  (.harness.sandbox_write_paths | index($write)) != null
' "$granted" >/dev/null || fail 'create did not store forwarded sandbox grants'

# --session names the session the runtime is derived from. Its settings are
# reused and its system components are rematerialized, without copying records.
print -r -- 'rematerialized system' >"$tmp/system/source.md"
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"old"}]}' \
  >>"$created"
reused=$(zsh -f "$entry" create --session "$created") || fail 'sourced create failed'
jq -e -s --slurpfile source "$created" '
  length == 2 and .[1] == {type:"system",content:"rematerialized system"} and
  (.[0] | del(.created)) == ($source[0] | del(.created))
' "$reused" >/dev/null || fail 'create did not reuse only the source settings'

# An occupied destination is never overwritten.
zsh -f "$entry" create --path "$explicit" --config "$config" >/dev/null 2>&1 &&
  fail 'create overwrote an existing session'

# Runtime overrides against an existing session stay rejected by config.
zsh -f "$entry" create --session "$created" --model other >/dev/null 2>&1 &&
  fail 'create accepted a runtime override with --session'

# Options create does not own are forwarded unparsed.
zsh -f "$entry" create --config "$tmp/missing.jsonc" >/dev/null 2>&1 &&
  fail 'create accepted an unreadable config'
zsh -f "$entry" create --path >/dev/null 2>&1 && fail 'create accepted a bare --path'
zsh -f "$entry" create --path "$tmp/a.jsonl" --path "$tmp/b.jsonl" >/dev/null 2>&1 &&
  fail 'create accepted a repeated --path'

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
SF_TEST_STATE_MARKER="$marker" zsh -f "$entry" create --path "$failed" \
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
zsh -f "$entry" create --path "$joined" --config "$joined_config" >/dev/null ||
  fail 'multi-component create failed'
jq -se 'length == 2 and .[1] == {type:"system",content:"first prompt\n\nsecond prompt"}' \
  "$joined" >/dev/null || fail 'create did not join the system components'

# An unreadable component fails without creating a transcript.
typeset missing="$tmp/missing.jsonl" missing_config="$tmp/missing.jsonc"
jq --arg path "$tmp/absent.md" '.profiles.machine.system=[$path]' "$config" >"$missing_config"
zsh -f "$entry" create --path "$missing" --config "$missing_config" >/dev/null 2>&1 &&
  fail 'a missing system component created a session'
[[ ! -e $missing ]] || fail 'create left a transcript for a missing component'

print -r -- ok
