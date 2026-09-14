#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

typeset stream
sf_test_tmp exec-tool-hook-errors
export XDG_STATE_HOME="$tmp/state"
sf_test_runtime
export SF_TEST_BACKEND_DELAY=0

# Post-hook skips fail the turn.
typeset post_skip="$tmp/post-skip"
cat >"$post_skip" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
exit 10
ZSH
chmod +x "$post_skip"
SF_TEST_RUNTIME=$(jq -c --arg hook "$post_skip" '
  del(.harness.pre_tool_use) | .harness.post_tool_use=[{command:$hook,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
typeset post_session="$tmp/post-failure.jsonl"
sf_test_session "$post_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 sf_test_turn fail "$post_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "tool_result")) | length) == 1 and
  ($events | map(select(.type == "tool_result"))[0].exit_code) == 0 and
  $events[-1].message == "post_tool_use hook script returned unsupported skip status"
' >/dev/null
assert_canonical_session "$post_session"
