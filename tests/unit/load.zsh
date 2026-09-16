#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp load-command

typeset entry="$ROOT/bin/shellfish"
typeset loaded session digest
integer load_status=0

digest() { cksum <"$1"; }

# Emit the path event, then the header and durable records in file order.
session="$tmp/complete.jsonl"
cp "$SF_TEST_SESSIONS/complete.jsonl" "$session"
loaded=$(zsh -f "$entry" load --session "$session") || fail 'load rejected a complete session'
jq -se --arg path "$session" --slurpfile session "$session" '
  .[0] == {type:"_session_load",path:$path} and
  .[1:] == $session
' <<<"$loaded" >/dev/null || fail 'load did not emit the canonical record stream'

# Resolve a relative request to an absolute path.
loaded=$(cd "$tmp" && zsh -f "$entry" load --session complete.jsonl) ||
  fail 'load rejected a relative session path'
jq -se --arg path "$session" '.[0] == {type:"_session_load",path:$path}' \
  <<<"$loaded" >/dev/null || fail 'load did not resolve the session path'

# Load a header without durable records.
loaded=$(zsh -f "$entry" load --session "$SF_TEST_SESSIONS/header-only.jsonl") ||
  fail 'load rejected a session without records'
jq -se 'length == 2 and .[1].type == "session"' <<<"$loaded" >/dev/null ||
  fail 'load did not emit a bare header'

# A structurally valid unfinished turn remains loadable.
loaded=$(zsh -f "$entry" load --session "$SF_TEST_SESSIONS/interrupted.jsonl") ||
  fail 'load rejected an unfinished turn'
jq -se 'length == 3 and .[-1].type == "user"' <<<"$loaded" >/dev/null ||
  fail 'load did not emit the unfinished turn'

# Ignore a final unterminated fragment without repairing it.
typeset fragment="$tmp/fragment.jsonl"
cp "$SF_TEST_SESSIONS/complete.jsonl" "$fragment"
print -rn -- '{"type":"assis' >>"$fragment"
digest=$(digest "$fragment")
loaded=$(zsh -f "$entry" load --session "$fragment") ||
  fail 'load rejected a session with a trailing fragment'
jq -se --slurpfile session "$SF_TEST_SESSIONS/complete.jsonl" '.[1:] == $session' \
  <<<"$loaded" >/dev/null || fail 'load did not ignore the trailing fragment'
assert_equal "$digest" "$(digest "$fragment")" 'load rewrote the session'

# Recover nothing: an unresolved tool call stays open for the next run.
typeset unresolved="$tmp/unresolved.jsonl"
head -n 3 "$SF_TEST_SESSIONS/tool-paired.jsonl" >"$unresolved"
digest=$(digest "$unresolved")
zsh -f "$entry" load --session "$unresolved" >/dev/null ||
  fail 'load rejected an unresolved tool call'
assert_equal "$digest" "$(digest "$unresolved")" 'load closed the interrupted turn'

# Validate the complete durable prefix before emitting anything.
typeset malformed="$tmp/malformed.jsonl" errors="$tmp/load.error"
cp "$SF_TEST_SESSIONS/complete.jsonl" "$malformed"
print -r -- '{"type":"user","content":[{"type":"text"}]}' >>"$malformed"
load_status=0
loaded=$(zsh -f "$entry" load --session "$malformed" 2>"$errors") || load_status=$?
(( load_status == 1 )) || fail 'load accepted a malformed record'
assert_equal '' "$loaded" 'load emitted records before validating the session'
[[ -s $errors ]] || fail 'load did not report why the session is invalid'

# Reject sessions that never had a canonical header.
print -r -- 'not json' >"$tmp/headerless.jsonl"
zsh -f "$entry" load --session "$tmp/headerless.jsonl" >/dev/null 2>&1 &&
  fail 'load accepted a session without a header'
: >"$tmp/empty.jsonl"
zsh -f "$entry" load --session "$tmp/empty.jsonl" >/dev/null 2>&1 &&
  fail 'load accepted an empty session'

# Reject paths that are not readable session files.
zsh -f "$entry" load --session "$tmp/absent.jsonl" >/dev/null 2>&1 &&
  fail 'load accepted a missing session'
ln -s "$session" "$tmp/link.jsonl"
zsh -f "$entry" load --session "$tmp/link.jsonl" >/dev/null 2>&1 &&
  fail 'load accepted a symlinked session'
zsh -f "$entry" load --session "$tmp" >/dev/null 2>&1 &&
  fail 'load accepted a directory'

# Require exactly one session argument.
load_status=0
zsh -f "$entry" load >/dev/null 2>&1 || load_status=$?
(( load_status == 2 )) || fail 'load accepted a missing --session'
load_status=0
zsh -f "$entry" load --session "$session" --session "$session" >/dev/null 2>&1 ||
  load_status=$?
(( load_status == 2 )) || fail 'load accepted a repeated --session'

print -r -- ok
