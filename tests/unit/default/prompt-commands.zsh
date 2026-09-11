#!/usr/bin/env zsh

source "${0:A:h:h}/_hooks.zsh"

sf_test_runtime

# The bundled help script reads frozen command metadata, then halts before
# unrelated prompt components.
typeset help_session="$tmp/help-session.jsonl" hook_events="$tmp/hook-events.jsonl"
typeset -g SF_TEST_HOOK_EVENTS=$hook_events
make_script after_help ': >"$SHELLFISH_TURN_STATE/after-help"'
typeset after_help=$script
SF_TEST_RUNTIME=$(jq -c \
  --arg help "$ROOT/share/default/hooks/user_prompt_submit/help/run" \
  --arg new "$ROOT/share/default/hooks/user_prompt_submit/new/run" \
  --arg refresh "$ROOT/share/default/hooks/user_prompt_submit/refresh/run" \
  --arg verbose "$ROOT/share/default/hooks/user_prompt_submit/verbose/run" \
  --arg copy "$ROOT/share/default/hooks/user_prompt_submit/copy/run" \
  --arg fork "$ROOT/share/default/hooks/user_prompt_submit/fork/run" \
  --arg sandbox "$ROOT/share/default/hooks/user_prompt_submit/sandbox/run" \
  --arg user_shell "$ROOT/share/default/hooks/user_prompt_submit/user_shell/run" \
  --arg server "$ROOT/share/default/hooks/user_prompt_submit/server/run" \
  --arg resume "$ROOT/share/default/hooks/user_prompt_submit/resume/run" \
  --arg compact "$ROOT/share/default/hooks/user_prompt_submit/compact/run" \
  --arg after_help "$after_help" \
  '.harness.sandbox=true |
   def command($command;$match;$usage;$description):
     {command:$command,display:"",environment:[],match:{pattern:$match},
      help:{usage:$usage,description:$description}};
   .harness.user_prompt_submit = [
     {command:$help,display:"",environment:[],match:{pattern:"^/(help|h)\\z"}},
     command($refresh;"^/(refresh|r)\\z";"/refresh, /r";"Rerender current session; fix layout"),
     command($verbose;"^/(verbose|v)\\z";"/verbose, /v";"Toggle full previews"),
     command($new;"^/new\\z";"/new";"Start a new session with the same settings"),
     command($copy;"^/copy( [^\\n]*)?\\z";"/copy [N]";"Copy the latest or selected user/agent section"),
     command($fork;"^/fork( [^\\n]*)?\\z";"/fork [N]";"Fork at the following user section (default: current end)"),
     command($sandbox;"^/sandbox( [^\\n]*)?\\z";"/sandbox [OP DIR]";"List or update session sandbox grants"),
     command($user_shell;"^![^\\n]*\\z";"!COMMAND";"Run COMMAND and stage its output as context"),
     command($server;"^/server\\z";"/server";"Serve this session in a browser"),
     command($resume;"^/resume\\z";"/resume";"Switch to a session for this directory"),
     command($compact;"^/compact\\z";"/compact";"Summarize this session into a new one"),
     {command:$after_help,display:"",environment:[]}
   ]' \
  <<<"$SF_TEST_RUNTIME")
sf_test_session "$help_session"
sf_session_begin_turn "$help_session"
sf_session_reset
sf_hooks_turn_state_create
run_prompt_hook /help "$help_session"
[[ $reply[1] == handled ]]
[[ ! -e $SHELLFISH_TURN_STATE/after-help ]]
typeset help_display=''
help_display=$(jq -r 'select(.type == "hook_result") | .user_context // empty' "$hook_events")
[[ $help_display == 'shift+enter'* ]]
(( ${#help_display} > 20 ))
# Every command key appears in the formatted output.
for key in '↑, ↓' '/queue drop <N>' '/queue clear' '/new' '/refresh, /r' '/verbose, /v' \
    '/copy [N]' '/fork [N]' '/sandbox [OP DIR]' '!COMMAND' '/server' '/resume' '/compact' \
    '/quit, /q'; do
  [[ $help_display == *"$key"* ]]
done
# Component rows follow configured order between framework rows and /quit.
typeset -a help_lines=( "${(@f)help_display}" )
integer control_idx history_idx drop_idx queue_idx refresh_idx new_idx bang_idx quit_idx i
for (( i = 1; i <= ${#help_lines}; i++ )); do
  [[ $help_lines[i] == *'ctrl+c'* ]] && control_idx=$i
  [[ $help_lines[i] == *'↑, ↓'* ]] && history_idx=$i
  [[ $help_lines[i] == *'/queue drop <N>'* ]] && drop_idx=$i
  [[ $help_lines[i] == *'/queue clear'* ]] && queue_idx=$i
  [[ $help_lines[i] == *'/refresh, /r'* ]] && refresh_idx=$i
  [[ $help_lines[i] == *'!COMMAND'* ]] && bang_idx=$i
  [[ $help_lines[i] == *'/new'* ]] && new_idx=$i
  [[ $help_lines[i] == *'/quit, /q'* ]] && quit_idx=$i
done
(( control_idx > 0 && history_idx > 0 && drop_idx > 0 && queue_idx > 0 &&
   refresh_idx > 0 && new_idx > 0 && bang_idx > 0 && quit_idx > 0 ))
(( control_idx < history_idx && history_idx < drop_idx && drop_idx < queue_idx &&
   queue_idx < refresh_idx && refresh_idx < new_idx && new_idx < bang_idx &&
   bang_idx < quit_idx ))
typeset control_prefix=${help_lines[control_idx]#ctrl+c}
typeset history_prefix=${help_lines[history_idx]#'↑, ↓'}
control_prefix=${control_prefix%%[^ ]*}
history_prefix=${history_prefix%%[^ ]*}
control_prefix="ctrl+c$control_prefix"
history_prefix="↑, ↓$history_prefix"
assert_equal "${#control_prefix}" "${#history_prefix}"

set_prompt_hook() {
  local session=$1 script=$2 patch
  integer rc=0
  patch=$(jq -cn --arg command "$script" \
    '{harness:{user_prompt_submit:[{command:$command,display:"",environment:[]}]}}') || return
  sf_session_begin_turn "$session" || return
  sf_session_update "$session" "$patch" || rc=1
  sf_session_reset
  return $rc
}

set_prompt_hook "$help_session" "$ROOT/share/default/hooks/user_prompt_submit/new/run"
run_prompt_hook /new "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --session-from && $reply[4] == "${help_session:A}" ]]

set_prompt_hook "$help_session" "$ROOT/share/default/hooks/user_prompt_submit/refresh/run"
run_prompt_hook /refresh "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --clear && $reply[4] == --session && $reply[5] == "${help_session:A}" ]]

# /verbose reloads the same session and toggles the preview limits.
set_prompt_hook "$help_session" "$ROOT/share/default/hooks/user_prompt_submit/verbose/run"
unset SHELLFISH_VERBOSE
run_prompt_hook /verbose "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --verbose && $reply[4] == --clear && $reply[5] == --session &&
   $reply[6] == "${help_session:A}" ]]
SHELLFISH_VERBOSE=1 run_prompt_hook /verbose "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --clear && $reply[4] == --session && $reply[5] == "${help_session:A}" ]]

set_prompt_hook "$help_session" "$ROOT/share/default/hooks/user_prompt_submit/server/run"
run_prompt_hook /server "$help_session"
[[ $reply[1] == handoff && $reply[2] == shellfish-server &&
   $reply[3] == --session && $reply[4] == "${help_session:A}" ]]

set_prompt_hook "$help_session" "$ROOT/share/default/hooks/user_prompt_submit/resume/run"
run_prompt_hook /resume "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --resume ]]

# /sandbox lists grants or requests a minimal in-place runtime update.
typeset sandbox_display='' sandbox_patch sandbox_dir="$tmp/output with spaces"
mkdir "$sandbox_dir"
set_prompt_hook "$help_session" "$ROOT/share/default/hooks/user_prompt_submit/sandbox/run"
run_prompt_hook /sandbox "$help_session"
[[ $reply[1] == handled ]]
sandbox_display=$(jq -r 'select(.type == "hook_result") | .user_context // empty' "$hook_events")
[[ $sandbox_display == *'Sandbox: enabled'* && $sandbox_display == *'Read grants:'* &&
   $sandbox_display == *'Write grants:'* ]]
run_prompt_hook "/sandbox +w $sandbox_dir" "$help_session"
[[ $reply[1] == session_update ]]
jq -se --arg path "${sandbox_dir:A}" '
  [.[] | select(.type == "hook_result" and .hook == "user_prompt_submit" and .script == "sandbox")]
    | .[-1].model_context | contains("added") and contains($path)
' "$help_session" >/dev/null || fail 'sandbox add did not commit model context'
sandbox_patch=$reply[2]
jq -e --arg path "${sandbox_dir:A}" \
  '. == {harness:{sandbox_write_paths:[$path]}}' <<<"$sandbox_patch" >/dev/null ||
  fail "unexpected sandbox patch: $sandbox_patch"
sf_session_begin_turn "$help_session"
sf_session_update "$help_session" "$sandbox_patch"
sf_session_reset
run_prompt_hook "/sandbox write $sandbox_dir" "$help_session"
[[ $reply[1] == handled ]]
run_prompt_hook "/sandbox -w $sandbox_dir" "$help_session"
[[ $reply[1] == session_update ]]
jq -se --arg path "${sandbox_dir:A}" '
  [.[] | select(.type == "hook_result" and .hook == "user_prompt_submit" and .script == "sandbox")]
    | .[-1].model_context | contains("removed") and contains($path)
' "$help_session" >/dev/null || fail 'sandbox removal did not commit model context'
jq -e '. == {harness:{sandbox_write_paths:[]}}' <<<"$reply[2]" >/dev/null

typeset disabled_session="$tmp/disabled-session.jsonl" enabled_runtime=$SF_TEST_RUNTIME
SF_TEST_RUNTIME=$(jq -c '.harness.sandbox=false' <<<"$SF_TEST_RUNTIME")
sf_hooks_turn_state_cleanup
sf_test_session "$disabled_session"
SF_TEST_RUNTIME=$enabled_runtime
sf_hooks_turn_state_create
set_prompt_hook "$disabled_session" "$ROOT/share/default/hooks/user_prompt_submit/sandbox/run"
run_prompt_hook "/sandbox +r $sandbox_dir" "$disabled_session"
[[ $reply[1] == handled ]]
sandbox_display=''
sandbox_display=$(jq -r 'select(.type == "hook_result") | .user_context // empty' "$hook_events")
[[ $sandbox_display == *disabled* ]] || fail 'disabled sandbox did not display its state'

sf_hooks_turn_state_cleanup

# Forking a fork starts a numbered sequence instead of repeating the suffix.
typeset fork_session="$tmp/fork-source_fork.jsonl"
typeset fork_control="$tmp/fork-control.json"
integer fork_status=0
jq -c '
  if .type == "user" then
    .content[0].text = "Hello\n\n"
  else . end
' "$SF_TEST_SESSIONS/complete.jsonl" >"$fork_session"
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  SHELLFISH_SESSION="$fork_session" SHELLFISH_TURN_STATE="$tmp" \
  zsh -f "$ROOT/share/default/hooks/user_prompt_submit/fork/run" user_prompt_submit \
  3>"$fork_control" < <(print -n -- '/fork 1') || fork_status=$?
(( fork_status == 11 ))
jq -e --arg command "$ROOT/bin/shellfish" \
  --arg path "$tmp/fork-source_fork_1.jsonl" \
  --arg draft $'Hello\n\n' \
  '. == {action:"handoff",argv:[$command,"--session",$path,"--draft",$draft]}' \
  "$fork_control" >/dev/null
[[ -s $tmp/fork-source_fork_1.jsonl ]]

fork_status=0
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  SHELLFISH_SESSION="$fork_session" SHELLFISH_TURN_STATE="$tmp" \
  zsh -f "$ROOT/share/default/hooks/user_prompt_submit/fork/run" user_prompt_submit \
  3>"$fork_control" < <(print -n -- /fork) || fork_status=$?
(( fork_status == 11 ))
jq -e --arg command "$ROOT/bin/shellfish" \
  --arg path "$tmp/fork-source_fork_2.jsonl" \
  '. == {action:"handoff",argv:[$command,"--session",$path]}' "$fork_control" >/dev/null

# /copy addresses derived user/agent sections and defaults to the latest one.
typeset copy_bin="$tmp/copy-bin" copy_output="$tmp/copied" copy_session="$tmp/copy-session.jsonl"
mkdir "$copy_bin"
cat >"$copy_bin/pbcopy" <<'EOF'
#!/bin/sh
cat >"$COPY_OUTPUT"
EOF
chmod +x "$copy_bin/pbcopy"
cat "$SF_TEST_SESSIONS/complete.jsonl" >"$copy_session"
print -r -- '{"type":"user","content":[{"type":"text","text":"Second"}]}' >>"$copy_session"
print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Answer"},{"type":"text","text":"Continued\n\n"}],"usage":{"input_tokens":1,"output_tokens":1}}' >>"$copy_session"
integer copy_status=0
COPY_OUTPUT="$copy_output" PATH="$copy_bin:$PATH" SHELLFISH_SESSION="$copy_session" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/share/default/hooks/user_prompt_submit/copy/run" \
  user_prompt_submit < <(print -n -- '/copy 1') || copy_status=$?
(( copy_status == 10 ))
assert_equal Hello "$(<$copy_output)"
copy_status=0
COPY_OUTPUT="$copy_output" PATH="$copy_bin:$PATH" SHELLFISH_SESSION="$copy_session" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/share/default/hooks/user_prompt_submit/copy/run" \
  user_prompt_submit < <(print -n -- /copy) || copy_status=$?
(( copy_status == 10 ))
print -n -- $'Answer\n\nContinued\n\n' >"$tmp/copy-expected"
cmp "$tmp/copy-expected" "$copy_output" >/dev/null || fail 'copy did not preserve assistant text'

# Agent section 2 and following user section 3 resolve to the same fork boundary.
integer fork_number=1
for target in 2 3; do
  fork_status=0
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$copy_session" \
    SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/share/default/hooks/user_prompt_submit/fork/run" \
    user_prompt_submit 3>"$fork_control" < <(print -n -- "/fork $target") || fork_status=$?
  (( fork_status == 11 ))
  jq -e --arg draft Second \
    '.argv[-2:] == ["--draft",$draft]' "$fork_control" >/dev/null
  jq -e -s '[.[] | select(.type == "user")] | length == 1' \
    "$tmp/copy-session_fork_${fork_number}.jsonl" >/dev/null
  (( fork_number++ ))
done

# Consecutive unanswered prompts remain distinct user sections.
typeset consecutive_session="$tmp/consecutive.jsonl"
head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl" >"$consecutive_session"
print -r -- \
  '{"type":"user","content":[{"type":"text","text":"First"}]}' \
  '{"type":"user","content":[{"type":"text","text":"Second"}]}' \
  >>"$consecutive_session"
fork_status=0
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$consecutive_session" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/share/default/hooks/user_prompt_submit/fork/run" \
  user_prompt_submit 3>"$fork_control" < <(print -n -- '/fork 2') || fork_status=$?
(( fork_status == 11 ))
jq -e --arg draft Second '.argv[-2:] == ["--draft",$draft]' "$fork_control" >/dev/null
jq -e -s '
  length == 2 and .[-1].type == "user" and .[-1].content[0].text == "First"
' "$tmp/consecutive_fork_1.jsonl" >/dev/null

# A fork is the exact prefix before the selected user: preceding state and
# context are kept, and the source is untouched.
typeset state_session="$tmp/state.jsonl"
head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl" >"$state_session"
print -r -- \
  '{"type":"state","name":"git/identity","value":"branch:main"}' \
  '{"type":"user","content":[{"type":"text","text":"First"}]}' \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Answer"}],"usage":{"input_tokens":1,"output_tokens":1}}' \
  '{"type":"state","name":"agents/a1b2c3","value":{"session":".agent-a1b2c3.jsonl"}}' \
  '{"type":"hook_result","hook":"user_prompt_submit","script":"git_environment","model_context":"branch:work"}' \
  '{"type":"user","content":[{"type":"text","text":"Second"}]}' \
  >>"$state_session"
typeset state_before=$(shasum <"$state_session")
fork_status=0
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$state_session" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/share/default/hooks/user_prompt_submit/fork/run" \
  user_prompt_submit 3>"$fork_control" < <(print -n -- '/fork 2') || fork_status=$?
(( fork_status == 11 ))
jq -e --arg draft Second '.argv[-2:] == ["--draft",$draft]' "$fork_control" >/dev/null
jq -e -s '
  [.[].type] == ["session","state","user","assistant","state","hook_result"] and
  [.[] | select(.type == "state") | .name] == ["git/identity","agents/a1b2c3"]
' "$tmp/state_fork_1.jsonl" >/dev/null || fail 'the fork is not the exact prefix'
assert_equal "$state_before" "$(shasum <"$state_session")"
[[ ! -e $tmp/.agent-a1b2c3.jsonl ]] || fail 'the fork copied a referenced internal session'

# The bundled shell shortcut records the normalized command and its nested exit
# status separately from the script's skip status.
typeset shell_session="$tmp/shell-session.jsonl"
SF_TEST_RUNTIME=$(jq -c \
  --arg script "$ROOT/share/default/hooks/user_prompt_submit/user_shell/run" \
  '.harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]' <<<"$SF_TEST_RUNTIME")
sf_test_session "$shell_session"
sf_session_begin_turn "$shell_session"
sf_session_reset
sf_hooks_turn_state_create
typeset -gx SHELLFISH_MODE=test SHELLFISH_VERBOSE=1
typeset shell_state_dir=$SHELLFISH_TURN_STATE
typeset shell_command='[[ -n $HOME ]] || exit 8; env | grep -Eq '\''^SHELLFISH_(SESSION|TURN_STATE|MAX_CAPTURE_BYTES|MODE|MODEL|TURN_ID|VERBOSE|CONFIG_DIR)='\'' && exit 9; [[ ! -e /dev/fd/3 ]] || exit 6; print output; exit 7'
run_prompt_hook "!$shell_command" "$shell_session"
[[ $reply[1] == handled ]]
[[ -d $shell_state_dir ]]
jq -e --arg prompt "$shell_command" '
  select(.type == "hook_result" and .hook == "user_prompt_submit" and
    .script == "user_shell" and .prompt == $prompt and
    .status == 7 and (.model_context | contains("output")))
' < <(tail -n 1 "$shell_session") >/dev/null
sf_hooks_turn_state_cleanup
unset SHELLFISH_MODE SHELLFISH_VERBOSE
assert_no_hook_captures
