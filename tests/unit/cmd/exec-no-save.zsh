#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp exec-no-save

typeset entry="$ROOT/bin/shellfish"
typeset backend="$tmp/backend"
mkdir "$backend"
cp "$ROOT/tests/fixtures/backend/run" "$ROOT/tests/fixtures/backend/backend.json" "$backend/"
typeset config="$tmp/shellfish.jsonc"
typeset prompt_hook="$tmp/prompt-hook"
cat >"$prompt_hook" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- 'INJECTED'
ZSH
chmod +x "$prompt_hook"
cat >"$config" <<EOF
{
  "default_profile": "exec",
  "backends": {"fixture": {"adapter": "$backend"}},
  "harnesses": {
    "machine": {
      "system": [], "tools": ["shell"], "sandbox": false,
      "session_start": [], "user_prompt_submit": ["$prompt_hook"],
      "permission_request": [], "pre_tool_use": [], "post_tool_use": [], "stop": [],
      "max_requests_per_turn": 8, "max_tool_calls_per_request": 16,
      "max_capture_bytes": 65536
    }
  },
  "profiles": {
    "exec": {
      "backend": "fixture", "harness": "machine",
      "request": {"model": "test-model"}
    }
  }
}
EOF
export XDG_STATE_HOME="$tmp/state"
export SF_TEST_BACKEND_DELAY=0

sf_digest() {
  shasum <"$1"
}

typeset session="$tmp/session.jsonl"
zsh -f "$entry" exec --config "$config" --session "$session" 'saved turn' </dev/null >/dev/null ||
  fail 'seed turn failed'
typeset seeded=$(sf_digest "$session")
typeset seeded_lines=$(wc -l <"$session")

# An ordinary completion keeps the whole prefix in the request and writes nothing.
typeset request="$tmp/request.json"
zsh -f "$entry" exec --config "$config" --session "$session" --no-save 'ephemeral turn' \
  </dev/null >"$tmp/ephemeral.out" || fail 'ephemeral turn failed'
[[ $(<"$tmp/ephemeral.out") == *'ephemeral turn' ]] ||
  fail 'an ephemeral turn did not print its answer'
assert_equal "$seeded" "$(sf_digest "$session")"
assert_equal "$seeded_lines" "$(wc -l <"$session")"
assert_session_unlocked "$session"

SF_TEST_BACKEND_REQUEST="$request" zsh -f "$entry" exec --config "$config" \
  --session "$session" --no-save 'projected turn' </dev/null >/dev/null ||
  fail 'projected turn failed'
jq -e '[.messages[] | .role] == ["user","assistant","user"] and
  (.messages[0].content[0].text | contains("saved turn")) and
  (.messages[2].content[0].text | contains("projected turn"))' "$request" >/dev/null ||
  fail 'an ephemeral turn did not project the durable prefix'
assert_equal "$seeded" "$(sf_digest "$session")"

# A multi-request tool turn executes normally and still writes nothing.
zsh -f "$entry" exec --config "$config" --session "$session" --no-save 'run a tool now' \
  </dev/null >/dev/null || fail 'ephemeral tool turn failed'
assert_equal "$seeded" "$(sf_digest "$session")"

# --no-hooks drops this turn's scripts but keeps durable context from earlier turns.
SF_TEST_BACKEND_REQUEST="$request" zsh -f "$entry" exec --config "$config" \
  --session "$session" --no-save --no-hooks 'unhooked turn' </dev/null >/dev/null ||
  fail 'unhooked turn failed'
jq -e '(.messages[0].content[0].text | contains("INJECTED")) and
  (.messages[-1].content[0].text == "unhooked turn")' "$request" >/dev/null ||
  fail '--no-hooks did not skip user_prompt_submit'
assert_equal "$seeded" "$(sf_digest "$session")"

# A source that would need repair or recovery is rejected before any work.
typeset unfinished="$tmp/unfinished.jsonl"
cp "$session" "$unfinished"
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"dangling"}]}' \
  >>"$unfinished"
typeset unfinished_digest=$(sf_digest "$unfinished")
zsh -f "$entry" exec --session "$unfinished" --no-save 'resume it' \
  </dev/null >/dev/null 2>"$tmp/unfinished.err" && fail 'an unfinished source was accepted'
[[ $(<"$tmp/unfinished.err") == *'unfinished turn'* ]] ||
  fail 'an unfinished source did not report why'
assert_equal "$unfinished_digest" "$(sf_digest "$unfinished")"

typeset partial="$tmp/partial.jsonl"
cp "$session" "$partial"
printf '%s' '{"type":"message","role":"user"' >>"$partial"
typeset partial_digest=$(sf_digest "$partial")
zsh -f "$entry" exec --session "$partial" --no-save 'repair it' \
  </dev/null >/dev/null 2>"$tmp/partial.err" && fail 'an incomplete final record was accepted'
[[ $(<"$tmp/partial.err") == *'incomplete final record'* ]] ||
  fail 'an incomplete final record did not report why'
assert_equal "$partial_digest" "$(sf_digest "$partial")"

# A discovered context window stays in memory rather than updating the header.
cat >"$backend/context_window" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- '{"context_window":4096}'
ZSH
chmod +x "$backend/context_window"
typeset window_session="$tmp/window.jsonl"
zsh -f "$entry" exec --config "$config" --session "$window_session" 'seed window' \
  </dev/null >/dev/null || fail 'context window seed failed'
jq -se '.[0].profile.context_window == 4096' "$window_session" >/dev/null ||
  fail 'a saved turn did not record the discovered context window'
jq -c 'if .type == "session" then (.profile |= del(.context_window)) else . end' \
  "$window_session" >"$tmp/window-cleared.jsonl"
typeset cleared_digest=$(sf_digest "$tmp/window-cleared.jsonl")
zsh -f "$entry" exec --session "$tmp/window-cleared.jsonl" --no-save 'discover again' \
  </dev/null >/dev/null || fail 'context window discovery turn failed'
assert_equal "$cleared_digest" "$(sf_digest "$tmp/window-cleared.jsonl")"
rm "$backend/context_window"

# A failing backend reports the error and leaves no partial or recovery records.
typeset failing="$tmp/failing"
mkdir "$failing"
cp "$ROOT/tests/fixtures/backend/backend.json" "$failing/"
cat >"$failing/run" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -ru2 -- 'provider exploded'
exit 1
ZSH
chmod +x "$failing/run"
typeset failing_config="$tmp/failing.jsonc"
sed "s#$backend#$failing#" "$config" >"$failing_config"
typeset failing_session
failing_session=$(zsh -f "$entry" exec --config "$failing_config" --new </dev/null) ||
  fail 'cannot create a session for the failing backend'
typeset failing_digest=$(sf_digest "$failing_session")
zsh -f "$entry" exec --session "$failing_session" --no-save 'boom' \
  </dev/null >/dev/null 2>"$tmp/failing.err" && fail 'a failing backend turn succeeded'
[[ $(<"$tmp/failing.err") == *'provider exploded'* ]] ||
  fail 'a failing backend did not report its error'
assert_equal "$failing_digest" "$(sf_digest "$failing_session")"
assert_session_unlocked "$failing_session"

# Cancellation converges on the same cleanup without touching the source.
typeset cancel_digest=$(sf_digest "$session")
SF_TEST_BACKEND_DELAY=0.3 zsh -f "$entry" exec --session "$session" --no-save \
  'a longer prompt with several words to stream slowly' </dev/null >/dev/null &
typeset cancel_pid=$!
sleep 1
kill -INT "$cancel_pid" 2>/dev/null || true
wait "$cancel_pid" && fail 'a cancelled turn exited successfully'
assert_equal "$cancel_digest" "$(sf_digest "$session")"
assert_session_unlocked "$session"

# Combinations without coherent semantics are rejected before any session work.
zsh -f "$entry" exec --config "$config" --no-save --new </dev/null >/dev/null 2>&1 &&
  fail '--no-save --new was accepted'
zsh -f "$entry" exec --config "$config" --session "$session" --no-save --jsonl \
  </dev/null >/dev/null 2>&1 && fail '--no-save --jsonl was accepted'
zsh -f "$entry" chat --no-save </dev/null >/dev/null 2>&1 &&
  fail '--no-save outside exec was accepted'
zsh -f "$entry" exec --config "$config" --session "$tmp/missing.jsonl" --no-save 'hi' \
  </dev/null >/dev/null 2>&1 && fail '--no-save created a session'
[[ ! -e $tmp/missing.jsonl ]] || fail '--no-save left a session behind'
