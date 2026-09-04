#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh lib/hooks.zsh

typeset stream
sf_test_tmp exec-tool-hook-errors
export XDG_STATE_HOME="$tmp/state"
export TEST_OUTPUT_DIR="$tmp/hook-output"
mkdir "$TEST_OUTPUT_DIR"
sf_test_runtime
export SF_TEST_BACKEND_DELAY=0

# Observer stdout and post-tool skip statuses are contract errors. Exec
# preserves already committed records and uses ordinary recovery to restore a
# valid await-user session state.
typeset pre_stdout="$tmp/pre-stdout"
cat >"$pre_stdout" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- unsupported
ZSH
chmod +x "$pre_stdout"
typeset post_never="$tmp/post-never"
cat >"$post_never" <<'ZSH'
#!/usr/bin/env zsh
: >"$TEST_OUTPUT_DIR/post-ran"
cat >/dev/null
ZSH
chmod +x "$post_never"
SF_TEST_RUNTIME=$(jq -c --arg pre "$pre_stdout" --arg post "$post_never" '
  .harness.pre_tool_use=[$pre] | .harness.post_tool_use=[$post]
' <<<"$SF_TEST_RUNTIME")
typeset pre_session="$tmp/pre-failure.jsonl"
sf_test_session "$pre_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 sf_test_turn fail "$pre_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result")) | length) == 1 and
  ($events | map(select(.role == "tool_result"))[0].exit_code) == 126 and
  $events[-2].role == "assistant" and $events[-2].stop == "end" and
  $events[-1].message == "pre_tool_use hook script wrote unsupported stdout"
' >/dev/null
[[ ! -e $TEST_OUTPUT_DIR/post-ran ]]
jq -L "$ROOT" -e -s '
  include "lib/runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$pre_session" >/dev/null

typeset post_skip="$tmp/post-skip"
cat >"$post_skip" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
exit 10
ZSH
chmod +x "$post_skip"
SF_TEST_RUNTIME=$(jq -c --arg hook "$post_skip" '
  del(.harness.pre_tool_use) | .harness.post_tool_use=[$hook]
' <<<"$SF_TEST_RUNTIME")
typeset post_session="$tmp/post-failure.jsonl"
sf_test_session "$post_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 sf_test_turn fail "$post_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result")) | length) == 1 and
  ($events | map(select(.role == "tool_result"))[0].exit_code) == 0 and
  $events[-2].role == "assistant" and $events[-2].stop == "end" and
  $events[-1].message == "post_tool_use hook script returned unsupported skip status"
' >/dev/null
jq -L "$ROOT" -e -s '
  include "lib/runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$post_session" >/dev/null
