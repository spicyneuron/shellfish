#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"

sf_test_runtime

# Command availability is best-effort, selects the first candidate with a
# usable version, and emits one separately attributed creation context.
typeset availability_hook="$ROOT/default/hooks/session_start/add_command_availability"
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
    "$availability_hook" session_start
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
if zsh -f "$availability_hook" user_prompt_submit >/dev/null 2>&1; then
  fail 'command availability accepted the wrong hook event'
fi

SF_TEST_RUNTIME=$(jq -c --arg hook "$availability_hook" \
  '.harness.session_start=[$hook]' <<<"$SF_TEST_RUNTIME")
sf_hooks_state_create
SF_SESSION_PATH=$availability_session
sf_session_prepare "$SF_TEST_RUNTIME"
sf_hooks_session_start "$availability_session"
sf_session_create "${SF_HOOK_CONTEXT_RECORDS[@]}"
sf_hooks_state_cleanup
jq -e -s '
  length == 2 and .[1].type == "context" and .[1].tag == "session_start" and
  .[1].hook == "add_command_availability" and
  (.[1].content | startswith("Host shell: zsh ") and
    contains("\nAvailable commands:\n"))
' "$availability_session" >/dev/null

# The bundled /help chain appends TSV rows to $SHELLFISH_STATE_DIR/help.tsv;
# the help hook (last in the chain) sorts by order and aligns columns. Verify
# structural properties, not exact text: submission is skipped, every command
# key appears, and rows are sorted by order ascending.
typeset help_session="$tmp/help-session.jsonl"
SF_TEST_RUNTIME=$(jq -c \
  --arg help "$ROOT/default/hooks/user_prompt_submit/help" \
  --arg new "$ROOT/default/hooks/user_prompt_submit/new" \
  --arg refresh "$ROOT/default/hooks/user_prompt_submit/refresh" \
  --arg verbose "$ROOT/default/hooks/user_prompt_submit/verbose" \
  --arg fork "$ROOT/default/hooks/user_prompt_submit/fork" \
  --arg user_shell "$ROOT/default/hooks/user_prompt_submit/user_shell" \
  --arg server "$ROOT/default/hooks/user_prompt_submit/server" \
  --arg resume "$ROOT/default/hooks/user_prompt_submit/resume" \
  '.harness.user_prompt_submit=[$new,$refresh,$verbose,$fork,$user_shell,$server,$resume,$help]' \
  <<<"$SF_TEST_RUNTIME")
sf_test_session "$help_session"
sf_session_open "$help_session"
sf_session_close
sf_hooks_state_create
run_prompt_hook /help "$help_session"
[[ $reply[1] == handled ]]
typeset help_display=''
integer result_index
for (( result_index = 4; result_index <= ${#SF_HOOK_RESULTS}; result_index += 5 )); do
  [[ -z $SF_HOOK_RESULTS[result_index] ]] || help_display=$SF_HOOK_RESULTS[result_index]
done
[[ $help_display == 'shift+enter'* ]]
(( ${#help_display} > 20 ))
# Every command key appears in the formatted output.
for key in '↑, ↓' '/queue drop <N>' '/queue clear' '/new' '/refresh, /r' '/verbose, /v' \
    '/fork [N]' '!COMMAND' '/server' '/resume' '/quit, /q'; do
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

# /verbose reloads the same session with the preview limits lifted.
run_prompt_hook /verbose "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --verbose && $reply[4] == --clear && $reply[5] == --session &&
   $reply[6] == "${help_session:A}" ]]

run_prompt_hook /server "$help_session"
[[ $reply[1] == handoff && $reply[2] == shellfish-server &&
   $reply[3] == --session && $reply[4] == "${help_session:A}" ]]

run_prompt_hook /resume "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --resume ]]
run_prompt_hook /r "$help_session"
[[ $reply[1] == handoff && $reply[2] == "$ROOT/bin/shellfish" &&
   $reply[3] == --clear && $reply[4] == --session && $reply[5] == "${help_session:A}" ]]
for former_alias in /n /f '/f 1'; do
  run_prompt_hook "$former_alias" "$help_session"
  [[ $reply[1] == proceed ]]
done
sf_hooks_state_cleanup

# Forking a fork starts a numbered sequence instead of repeating the suffix.
typeset fork_session="$tmp/fork-source_fork.jsonl"
typeset fork_control="$tmp/fork-control.json"
integer fork_status=0
cp "$SF_TEST_SESSIONS/complete.jsonl" "$fork_session"
SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  SHELLFISH_SESSION="$fork_session" SHELLFISH_STATE_DIR="$tmp" \
  zsh -f "$ROOT/default/hooks/user_prompt_submit/fork" user_prompt_submit \
  3>"$fork_control" < <(print -n -- /fork) || fork_status=$?
(( fork_status == 11 ))
jq -e --arg command "$ROOT/bin/shellfish" \
  --arg path "$tmp/fork-source_fork_1.jsonl" \
  '. == {action:"handoff",argv:[$command,"--session",$path]}' "$fork_control" >/dev/null
[[ -s $tmp/fork-source_fork_1.jsonl ]]

# The bundled shell shortcut records the normalized command and its nested exit
# status separately from the hook's skip status.
typeset shell_session="$tmp/shell-session.jsonl"
SF_TEST_RUNTIME=$(jq -c \
  --arg hook "$ROOT/default/hooks/user_prompt_submit/user_shell" \
  '.harness.user_prompt_submit=[$hook]' <<<"$SF_TEST_RUNTIME")
sf_test_session "$shell_session"
sf_session_open "$shell_session"
sf_session_close
sf_hooks_state_create
typeset -gx SHELLFISH_MODE=test
typeset shell_state_dir=$SHELLFISH_STATE_DIR
typeset shell_command='[[ -n $HOME ]] || exit 8; env | grep -Eq '\''^(SHELLFISH_(SESSION|SESSION_ID|STATE_DIR|CAPTURE_LIMIT|MODE|MODEL|TURN_ID)|PROJECT_DIR|PLUGIN_ROOT|PLUGIN_DATA)='\'' && exit 9; print output; exit 7'
run_prompt_hook "!$shell_command" "$shell_session"
[[ $reply[1] == handled ]]
[[ -d $shell_state_dir ]]
jq -e --arg prompt "$shell_command" '
  select(.type == "context" and .tag == "user_prompt_submit" and
    .hook == "user_shell" and .prompt == $prompt and
    .status == 7 and (.content | contains("output")))
' < <(tail -n 1 "$shell_session") >/dev/null
sf_hooks_state_cleanup
unset SHELLFISH_MODE
assert_no_hook_captures
