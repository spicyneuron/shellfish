#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"

sf_test_runtime

# A slow directory tree acts as a filesystem canary, preventing git status
# from walking the worktree without blocking the remaining git context.
typeset environment_script="$ROOT/default/hooks/session_start/add_environment"
typeset environment_bin="$tmp/environment-bin"
typeset environment_output
typeset -i environment_started environment_elapsed
mkdir "$environment_bin"
cat >"$environment_bin/tree" <<'EOF'
#!/bin/sh
exec sleep 10
EOF
cat >"$environment_bin/git" <<'EOF'
#!/bin/sh
case "$1" in
  rev-parse) printf '.git\n' ;;
  branch) printf 'main\n' ;;
  status) printf 'status should have been skipped\n' ;;
  log)
    case "$2" in
      --oneline) printf 'abc123 Test commit\n' ;;
      --name-status) printf 'M\tchanged-file\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$environment_bin/tree" "$environment_bin/git"
environment_started=$SECONDS
environment_output=$(PATH="$environment_bin:$PATH" zsh -f "$environment_script" session_start)
environment_elapsed=$(( SECONDS - environment_started ))
(( environment_elapsed >= 3 && environment_elapsed < 7 )) ||
  fail "environment tree timeout took ${environment_elapsed}s"
[[ $environment_output == *'tree: (skipped, slow file system)'* ]]
[[ $environment_output == *$'Git branch: main'* ]]
[[ $environment_output == *$'Git status:\n(skipped, slow filesystem)'* ]]
[[ $environment_output == *$'Recent commits:\nabc123 Test commit'* ]]
[[ $environment_output == *$'Recent files:\n M changed-file'* ]]
[[ $environment_output != *'status should have been skipped'* ]]

cat >"$environment_bin/git" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$environment_bin/tree" <<'EOF'
#!/bin/sh
printf '.\n'
EOF
chmod +x "$environment_bin/tree" "$environment_bin/git"
environment_output=$(PATH="$environment_bin:$PATH" zsh -f "$environment_script" session_start)
[[ $environment_output == *'Not in git repo'* ]]

# Command availability is best-effort, selects the first candidate with a
# usable version, and emits one separately attributed creation context.
typeset availability_script="$ROOT/default/hooks/session_start/add_command_availability"
typeset availability_bin="$tmp/availability-bin"
typeset availability_output availability_rows availability_session="$tmp/availability-session.jsonl"
mkdir "$availability_bin"
ln -s "${commands[zsh]:A}" "$availability_bin/zsh"
make_version_command() {
  local name=$1 body=$2
  print -r -- '#!/bin/sh' >"$availability_bin/$name"
  print -r -- "$body" >>"$availability_bin/$name"
  chmod +x "$availability_bin/$name"
}
make_version_command rg 'exit 2'
make_version_command grep "printf 'grep 1.0\\nignored\\n'"
make_version_command find 'exit 2'
make_version_command what "printf 'archive PROGRAM:find  PROJECT:find-2.1 other\\n'"
make_version_command jq "printf 'jq-1.7\\n'"
make_version_command yq 'exit 0'
make_version_command python3 "printf 'Python 3.13\\n' >&2"
make_version_command git "printf 'git version 2.48\\n'"
make_version_command gh 'exit 2'

availability_output=$(
  /usr/bin/env PATH="$availability_bin" "$availability_bin/zsh" -f \
    "$availability_script" session_start
)
typeset -a availability_lines=( "${(@f)availability_output}" )
assert_equal "Host shell: zsh $ZSH_VERSION" "$availability_lines[1]"
assert_equal 'Available commands:' "$availability_lines[2]"
availability_rows=$(jq -Rsc '
  [split("\n")[] |
    capture("^- (?<label>[^:]+): (?<command>[^ ]+) \\((?<version>.*)\\)$")?] |
  INDEX(.label)
' <<<"$availability_output") || fail 'cannot parse command availability output'
jq -e '
  length == 5 and
  .search.command == "grep" and .search.version == "grep 1.0" and
  .files.command == "find" and .files.version == "find-2.1" and
  .JSON.command == "jq" and .JSON.version == "jq-1.7" and
  .Python.command == "python3" and .Python.version == "Python 3.13" and
  .VCS.command == "git" and .VCS.version == "git version 2.48" and
  (has("trees") | not) and (has("YAML") | not) and (has("GitHub") | not)
' <<<"$availability_rows" >/dev/null
if zsh -f "$availability_script" user_prompt_submit >/dev/null 2>&1; then
  fail 'command availability accepted the wrong hook name'
fi

SF_TEST_RUNTIME=$(jq -c --arg script "$availability_script" \
  '.harness.session_start=[$script]' <<<"$SF_TEST_RUNTIME")
SF_SESSION_PATH=$availability_session
SHELLFISH_SESSION_STATE=''
sf_hooks_session_state_create
sf_session_prepare "$SF_TEST_RUNTIME"
sf_hooks_session_start "$availability_session"
sf_session_create "${SF_HOOK_CONTEXT_RECORDS[@]}"
sf_hooks_turn_state_cleanup
jq -e -s '
  length == 2 and .[1].type == "context" and .[1].hook == "session_start" and
  .[1].script == "add_command_availability" and
  (.[1].content | startswith("Host shell: zsh ") and
    contains("\nAvailable commands:\n"))
' "$availability_session" >/dev/null

# The bundled /help chain appends TSV rows to $SHELLFISH_TURN_STATE/help.tsv;
# the help script (last in the chain) sorts by order and aligns columns. Verify
# structural properties, not exact text: submission is skipped, every command
# key appears, and rows are sorted by order ascending.
typeset help_session="$tmp/help-session.jsonl"
SF_TEST_RUNTIME=$(jq -c \
  --arg help "$ROOT/default/hooks/user_prompt_submit/help" \
  --arg new "$ROOT/default/hooks/user_prompt_submit/new" \
  --arg refresh "$ROOT/default/hooks/user_prompt_submit/refresh" \
  --arg verbose "$ROOT/default/hooks/user_prompt_submit/verbose" \
  --arg copy "$ROOT/default/hooks/user_prompt_submit/copy" \
  --arg fork "$ROOT/default/hooks/user_prompt_submit/fork" \
  --arg sandbox "$ROOT/default/hooks/user_prompt_submit/sandbox" \
  --arg user_shell "$ROOT/default/hooks/user_prompt_submit/user_shell" \
  --arg server "$ROOT/default/hooks/user_prompt_submit/server" \
  --arg resume "$ROOT/default/hooks/user_prompt_submit/resume" \
  '.harness.sandbox=true |
   .harness.user_prompt_submit=[$new,$refresh,$verbose,$copy,$fork,$sandbox,$user_shell,$server,$resume,$help]' \
  <<<"$SF_TEST_RUNTIME")
sf_test_session "$help_session"
sf_session_open "$help_session"
sf_session_close
sf_hooks_turn_state_create
run_prompt_hook /help "$help_session"
[[ $reply[1] == handled ]]
typeset help_display=''
integer result_index
for (( result_index = 4; result_index <= ${#SF_HOOK_SCRIPT_RESULTS}; result_index += 5 )); do
  [[ -z $SF_HOOK_SCRIPT_RESULTS[result_index] ]] || help_display=$SF_HOOK_SCRIPT_RESULTS[result_index]
done
[[ $help_display == 'shift+enter'* ]]
(( ${#help_display} > 20 ))
# Every command key appears in the formatted output.
for key in '↑, ↓' '/queue drop <N>' '/queue clear' '/new' '/refresh, /r' '/verbose, /v' \
    '/copy [N]' '/fork [N]' '/sandbox [OP DIR]' '!COMMAND' '/server' '/resume' '/quit, /q'; do
  [[ $help_display == *"$key"* ]]
done
# Rows remain sorted by their configured order through /quit.
typeset -a help_lines=( "${(@f)help_display}" )
integer control_idx history_idx drop_idx queue_idx bang_idx new_idx quit_idx i
for (( i = 1; i <= ${#help_lines}; i++ )); do
  [[ $help_lines[i] == *'ctrl+c'* ]] && control_idx=$i
  [[ $help_lines[i] == *'↑, ↓'* ]] && history_idx=$i
  [[ $help_lines[i] == *'/queue drop <N>'* ]] && drop_idx=$i
  [[ $help_lines[i] == *'/queue clear'* ]] && queue_idx=$i
  [[ $help_lines[i] == *'!COMMAND'* ]] && bang_idx=$i
  [[ $help_lines[i] == *'/new'* ]] && new_idx=$i
  [[ $help_lines[i] == *'/quit, /q'* ]] && quit_idx=$i
done
(( control_idx > 0 && history_idx > 0 && drop_idx > 0 && queue_idx > 0 && bang_idx > 0 &&
   new_idx > 0 && quit_idx > 0 ))
(( control_idx < history_idx && history_idx < bang_idx && bang_idx < drop_idx &&
   drop_idx < queue_idx && queue_idx < new_idx && new_idx < quit_idx ))
typeset control_prefix=${help_lines[control_idx]%%Cancel*}
typeset history_prefix=${help_lines[history_idx]%%Navigate*}
assert_equal "${#control_prefix}" "${#history_prefix}"

run_prompt_hook /refresh "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --clear && $reply[4] == --session && $reply[5] == "${help_session:A}" ]]

# /verbose reloads the same session and toggles the preview limits.
unset SHELLFISH_VERBOSE
run_prompt_hook /verbose "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --verbose && $reply[4] == --clear && $reply[5] == --session &&
   $reply[6] == "${help_session:A}" ]]
SHELLFISH_VERBOSE=1 run_prompt_hook /verbose "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --clear && $reply[4] == --session && $reply[5] == "${help_session:A}" ]]

run_prompt_hook /server "$help_session"
[[ $reply[1] == handoff && $reply[2] == shellfish-server &&
   $reply[3] == --session && $reply[4] == "${help_session:A}" ]]

run_prompt_hook /resume "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --resume ]]
run_prompt_hook /r "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --clear && $reply[4] == --session && $reply[5] == "${help_session:A}" ]]

# /sandbox lists grants without reloading and hands a minimal runtime patch to
# the ordinary reload path for changes.
typeset sandbox_display='' sandbox_patch sandbox_dir="$tmp/output with spaces"
mkdir "$sandbox_dir"
run_prompt_hook /sandbox "$help_session"
[[ $reply[1] == handled ]]
for (( result_index = 4; result_index <= ${#SF_HOOK_SCRIPT_RESULTS}; result_index += 5 )); do
  [[ -z $SF_HOOK_SCRIPT_RESULTS[result_index] ]] || sandbox_display=$SF_HOOK_SCRIPT_RESULTS[result_index]
done
[[ $sandbox_display == *'Sandbox: enabled'* && $sandbox_display == *'Read grants:'* &&
   $sandbox_display == *'Write grants:'* ]]
run_prompt_hook "/sandbox +w $sandbox_dir" "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --clear && $reply[4] == --session && $reply[5] == "${help_session:A}" &&
   $reply[6] == --session-update ]]
sandbox_patch=$reply[7]
jq -e --arg path "${sandbox_dir:A}" \
  '. == {harness:{sandbox_write_paths:[$path]}}' <<<"$sandbox_patch" >/dev/null ||
  fail "unexpected sandbox patch: $sandbox_patch"
sf_session_open "$help_session"
sf_session_update "$sandbox_patch"
sf_session_close
run_prompt_hook "/sandbox write $sandbox_dir" "$help_session"
[[ $reply[1] == handled ]]
run_prompt_hook "/sandbox -w $sandbox_dir" "$help_session"
[[ $reply[1] == handoff && $reply[6] == --session-update ]]
jq -e '. == {harness:{sandbox_write_paths:[]}}' <<<"$reply[7]" >/dev/null

typeset disabled_session="$tmp/disabled-session.jsonl" enabled_runtime=$SF_TEST_RUNTIME
SF_TEST_RUNTIME=$(jq -c '.harness.sandbox=false' <<<"$SF_TEST_RUNTIME")
sf_test_session "$disabled_session"
SF_TEST_RUNTIME=$enabled_runtime
run_prompt_hook "/sandbox +r $sandbox_dir" "$disabled_session"
[[ $reply[1] == handled ]]
for (( result_index = 4; result_index <= ${#SF_HOOK_SCRIPT_RESULTS}; result_index += 5 )); do
  [[ -z $SF_HOOK_SCRIPT_RESULTS[result_index] ]] || sandbox_display=$SF_HOOK_SCRIPT_RESULTS[result_index]
done
[[ $sandbox_display == 'session sandbox is disabled'* ]] ||
  fail "unexpected disabled sandbox display: $sandbox_display"

for former_alias in /n /f '/f 1'; do
  run_prompt_hook "$former_alias" "$help_session"
  [[ $reply[1] == proceed ]]
done
sf_hooks_turn_state_cleanup

# Forking a fork starts a numbered sequence instead of repeating the suffix.
typeset fork_session="$tmp/fork-source_fork.jsonl"
typeset fork_control="$tmp/fork-control.json"
integer fork_status=0
jq -c '
  if .type == "message" and .role == "user" then
    .content[0].text = "Hello\n\n"
  else . end
' "$SF_TEST_SESSIONS/complete.jsonl" >"$fork_session"
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  SHELLFISH_SESSION="$fork_session" SHELLFISH_TURN_STATE="$tmp" \
  zsh -f "$ROOT/default/hooks/user_prompt_submit/fork" user_prompt_submit \
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
  zsh -f "$ROOT/default/hooks/user_prompt_submit/fork" user_prompt_submit \
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
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"Second"}]}' >>"$copy_session"
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"Answer"},{"type":"text","text":"Continued\n\n"}],"usage":{"input_tokens":1,"output_tokens":1}}' >>"$copy_session"
integer copy_status=0
COPY_OUTPUT="$copy_output" PATH="$copy_bin:$PATH" SHELLFISH_SESSION="$copy_session" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/default/hooks/user_prompt_submit/copy" \
  user_prompt_submit < <(print -n -- '/copy 1') || copy_status=$?
(( copy_status == 10 ))
assert_equal Hello "$(<$copy_output)"
copy_status=0
COPY_OUTPUT="$copy_output" PATH="$copy_bin:$PATH" SHELLFISH_SESSION="$copy_session" \
  SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/default/hooks/user_prompt_submit/copy" \
  user_prompt_submit < <(print -n -- /copy) || copy_status=$?
(( copy_status == 10 ))
print -n -- $'Answer\n\nContinued\n\n' >"$tmp/copy-expected"
cmp "$tmp/copy-expected" "$copy_output" >/dev/null || fail 'copy did not preserve assistant text'

# Agent section 2 and following user section 3 resolve to the same fork boundary.
integer fork_number=1
for target in 2 3; do
  fork_status=0
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" SHELLFISH_SESSION="$copy_session" \
    SHELLFISH_TURN_STATE="$tmp" zsh -f "$ROOT/default/hooks/user_prompt_submit/fork" \
    user_prompt_submit 3>"$fork_control" < <(print -n -- "/fork $target") || fork_status=$?
  (( fork_status == 11 ))
  jq -e --arg draft Second \
    '.argv[-2:] == ["--draft",$draft]' "$fork_control" >/dev/null
  jq -e -s '[.[] | select(.type == "message" and .role == "user")] | length == 1' \
    "$tmp/copy-session_fork_${fork_number}.jsonl" >/dev/null
  (( fork_number++ ))
done

# The bundled shell shortcut records the normalized command and its nested exit
# status separately from the script's skip status.
typeset shell_session="$tmp/shell-session.jsonl"
SF_TEST_RUNTIME=$(jq -c \
  --arg script "$ROOT/default/hooks/user_prompt_submit/user_shell" \
  '.harness.user_prompt_submit=[$script]' <<<"$SF_TEST_RUNTIME")
sf_test_session "$shell_session"
sf_session_open "$shell_session"
sf_session_close
sf_hooks_turn_state_create
typeset -gx SHELLFISH_MODE=test SHELLFISH_VERBOSE=1
typeset shell_state_dir=$SHELLFISH_TURN_STATE
typeset shell_command='[[ -n $HOME ]] || exit 8; env | grep -Eq '\''^(SHELLFISH_(SESSION|SESSION_ID|TURN_STATE|SESSION_STATE|CAPTURE_LIMIT|MODE|MODEL|TURN_ID|VERBOSE|CONFIG_DIR)|PROJECT_DIR|HOOK_SCRIPT_ROOT)='\'' && exit 9; print output; exit 7'
run_prompt_hook "!$shell_command" "$shell_session"
[[ $reply[1] == handled ]]
[[ -d $shell_state_dir ]]
jq -e --arg prompt "$shell_command" '
  select(.type == "context" and .hook == "user_prompt_submit" and
    .script == "user_shell" and .prompt == $prompt and
    .status == 7 and (.content | contains("output")))
' < <(tail -n 1 "$shell_session") >/dev/null
sf_hooks_turn_state_cleanup
unset SHELLFISH_MODE SHELLFISH_VERBOSE
assert_no_hook_captures
