#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
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

print -r -- ok
