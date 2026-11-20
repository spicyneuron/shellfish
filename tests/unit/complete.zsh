#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp complete
sf_test_frozen_profile
typeset app=$ROOT/bin/shellfish project="$tmp/project space" session=$tmp/complete.jsonl
typeset hook=$tmp/probe

sf_test_hook "$hook" '{"complete":"%","on":"user_prompt_submit","match":{"pattern":"never"}}' <<'SH'
#!/bin/sh
exit 99
SH
cat >"$hook/complete" <<'SH'
#!/bin/sh
set -eu
[ "$#" = 1 ]
[ "$1" = "%ec" ]
[ "$PWD" = "$EXPECTED_CWD" ]
[ "$SHELLFISH_CONFIG" = '{"skills":["skill-local","skill-user","skill-config"]}' ]
[ "$SHELLFISH_SESSION" = "$EXPECTED_SESSION" ]
[ "$SHELLFISH_MODEL" = test-model ]
[ "$SHELLFISH_VERBOSE" = 1 ]
[ "$SHELLFISH_MODE" = run ]
[ -x "$SHELLFISH_EXECUTABLE" ]
[ -d "$SHELLFISH_SHARE_DIR/lib" ]
[ "$COMPLETE_ENV" = from-file ]
[ "$COMPLETE_OVERRIDE" = exported ]
[ -z "${SHELLFISH_TURN_ID+x}${SHELLFISH_TURN_STATE+x}" ]
if read -r line; then exit 1; fi
printf '%%echo\n'
SH
chmod +x "$hook/complete"
typeset -x SHELLFISH_VERBOSE=1 COMPLETE_OVERRIDE=exported
mkdir -p "$SHELLFISH_DIR"
printf '%s\n' 'COMPLETE_ENV=from-file' 'COMPLETE_OVERRIDE=from-file' 'SHELLFISH_MODEL=wrong' \
  'SHELLFISH_TURN_ID=wrong' "EXPECTED_CWD=$project" "EXPECTED_SESSION=$session" >"$SHELLFISH_DIR/.env"
typeset dir name disabled
for dir name disabled in \
  "$project/.agents/skills" skill-local false \
  "$project/.agents/skills" skill-hidden false \
  "$project/.agents/skills" skill-user true \
  "$SHELLFISH_DIR/skills" skill-config false; do
  mkdir -p "$dir/$name"
  printf '%s\n' --- "name: $name" 'description: A completion fixture' \
    "disable-model-invocation: $disabled" --- "Body for $name" >"$dir/$name/SKILL.md"
done
SF_TEST_PROFILE=$(jq -c --arg hook "$hook" '
  .hooks = ["@hooks/skills/mention", $hook] |
  .config.skills = ["skill-local","skill-user","skill-config"]
' <<<"$SF_TEST_PROFILE")
( builtin cd -- "$project"; sf_test_session "$session" )

typeset before=$(<"$session") output
output=$("$app" complete --session "$session" '%ec')
assert_equal '%echo' "$output"
output=$("$app" complete --session "$session" '$skill-')
assert_equal $'$skill-local\n$skill-user\n$skill-config' "$output"
output=$("$app" complete --session "$session" '$skill-u')
assert_equal '$skill-user' "$output"
output=$("$app" complete --session "$session" '$skill-h')
assert_equal '' "$output"
output=$("$app" complete --session "$session" '#')
assert_equal '' "$output"
assert_equal "$before" "$(<"$session")"
[[ ! -e $session.lock ]]

chmod -x "$hook/complete"
if "$app" complete --session "$session" '%ec' >"$tmp/output" 2>"$tmp/error"; then
  fail 'nonexecutable completer succeeded'
fi
[[ ! -s $tmp/output && $(<"$tmp/error") == *'hook completer is not executable:'* ]]
print -r -- '{"on":"user_prompt_submit","complete":"two"}' >"$hook/manifest.json"
if "$app" complete --session "$session" '%ec' >"$tmp/output" 2>"$tmp/error"; then
  fail 'invalid completion prefix succeeded'
fi
[[ ! -s $tmp/output && $(<"$tmp/error") == *'hook manifest must be valid'* ]]
