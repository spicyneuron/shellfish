#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-environment

# Model context emitted by the Git checkout prompt hook.
settled() { jq -rs 'map(select(has("model_text"))) | last.model_text // ""' "$1"; }

# Capture project context through the default startup list.
typeset environment_bin="$tmp/environment-bin"
mkdir "$environment_bin"
cat >"$environment_bin/tree" <<'EOF'
#!/bin/sh
printf '.\n'
EOF
chmod +x "$environment_bin/tree"
# Record Git identity transitions.
typeset git_environment="$ROOT/share/hooks/git/environment/run"
typeset git_prompt="$ROOT/share/hooks/git/change"
typeset git_bin="$tmp/git-environment-bin" git_state="$tmp/git-state"
typeset git_session="$tmp/git-session.jsonl" git_control="$tmp/git-control.json" git_output
mkdir "$git_bin"
cat >"$git_bin/git" <<'EOF'
#!/bin/sh
IFS= read -r state <"$GIT_STATE" || state=
case "$1:$2" in
  rev-parse:--verify) printf '%s\n' "${state#commit:}" ;;
  log:--oneline) printf 'abc123 Test commit\n' ;;
  status:--short) printf 'M status-file\n' ;;
  symbolic-ref:--quiet)
    case "$state" in
      branch:*) printf '%s\n' "${state#branch:}" ;;
      commit:*) exit 1 ;;
      *) exit 128 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$git_bin/git"
print -r -- 'branch:main' >"$git_state"
# The default startup list renders captured context and persists state first.
sf_test_config
sf_test_profile default "{\"extend\":[\"@default\"],
  \"backend\":{\"adapter\":\"$ROOT/tests/fixtures/backend\"},
  \"request\":{\"model\":\"test\"},\"hooks\":{\"user_prompt_submit\":[]}}"
startup() {
  rm -f "$tmp/startup.jsonl"
  PATH="$environment_bin:$git_bin:$PATH" GIT_STATE="$git_state" \
    "$ROOT/bin/shellfish" run --jsonl --session-create --session-out "$tmp/startup.jsonl" \
    >"$tmp/startup.stream"
  assert_canonical_session "$tmp/startup.jsonl"
}
startup
jq -e -s '
  [ .[] | select(.type == "state" or .type == "hook_result") ] as $results |
  ($results | map(.type)) == ["hook_result","state","hook_result","hook_result"] and
  ($results[0].user_text | startswith("Project environment:\n")) and
  ($results[0].model_text | startswith("<context script=\"project/environment\">\n")) and
  ($results[0].model_text | contains("PWD: ") and contains("\n.") and
    contains("Available commands:") and contains("Available agent skills.") and
    contains("- skill-creator: ") and (contains("Git ") | not)) and
  $results[1].name == "git/identity" and $results[1].value == "branch:main" and
  ($results[2].user_text | startswith("Git environment:\nGit branch: main")) and
  ($results[2].model_text | startswith("<context script=\"git/environment\">\n") and
    contains("abc123 Test commit") and contains("status-file") and
    (contains("Recent files:") | not))
' "$tmp/startup.jsonl" >/dev/null || fail 'default startup context or state ordering changed'
jq -c 'select(.type == "state")' "$tmp/startup.jsonl" >"$git_session"
print -r -- '{"type":"state","name":"git/other","value":"ignored"}' >>"$git_session"
print -r -- $'#!/bin/sh\nexit 124' >"$environment_bin/tree"
print -r -- 'commit:0123456789abcdef' >"$git_state"
startup
jq -e -s 'any(.[]; .type == "state" and .value == "commit:0123456789abcdef") and
  any(.[]; (.user_text // "" | contains("(detached HEAD)"))) and
  any(.[]; (.model_text // "" | contains("Filesystem context: (skipped, slow file system)") and
    contains("Available commands:") and contains("Available agent skills.")))' \
  "$tmp/startup.jsonl" >/dev/null || fail 'detached startup context was lost'
print -r -- 'none' >"$git_state"
startup
jq -e -s 'all(.[]; .type != "state" and
  (.user_text // "" | startswith("Git environment:") | not))' \
  "$tmp/startup.jsonl" >/dev/null || fail 'no-repository startup was not silent'
jq -e -s 'any(.[]; .type == "_draft" and .user_text == "Loading git environment…") and
  any(.[]; .type == "_draft" and .user_text == "")' "$tmp/startup.stream" >/dev/null
print -r -- 'branch:main' >"$git_state"

git_change() {
  PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION="$git_session" \
    zsh -f "$git_prompt" user_prompt_submit 3>"$git_control"
  git_output=$(settled "$git_control")
}
git_change
assert_equal '' "$git_output"
[[ ! -s $git_control ]]
print -r -- 'branch:feature' >"$git_state"
git_change
[[ $git_output == *main* && $git_output == *feature* ]]
[[ $git_output == '<context script="git/change">'$'\n'*$'\n</context>' ]]
jq -e -s 'map(select(has("user_text"))) | last.user_text == "Git checkout changed:\nmain → feature"' \
  "$git_control" >/dev/null
jq -e -s 'map(.state // empty) | last == [{name:"git/identity",value:"branch:feature"}]' \
  "$git_control" >/dev/null
jq -c '.state[]? | {type:"state"} + .' "$git_control" >>"$git_session"
git_change
assert_equal '' "$git_output"
[[ ! -s $git_control ]]

print -r -- 'commit:0123456789abcdef' >"$git_state"
git_change
[[ $git_output == *feature* && $git_output == *0123456789abcdef* ]]
jq -e -s 'map(select(has("user_text"))) | last.user_text == "Git checkout changed:\nfeature → detached commit 0123456789abcdef"' \
  "$git_control" >/dev/null
jq -e -s 'map(.state // empty) | last == [{name:"git/identity",value:"commit:0123456789abcdef"}]' \
  "$git_control" >/dev/null
jq -c '.state[]? | {type:"state"} + .' "$git_control" >>"$git_session"

cat >"$git_bin/git" <<'EOF'
#!/bin/sh
exit 124
EOF
chmod +x "$git_bin/git"
git_change
assert_equal '' "$git_output"
[[ ! -s $git_control ]]

PATH="$git_bin:$PATH" zsh -f "$git_environment" session_start \
  3>"$git_control" >"$tmp/git-output"
[[ ! -s $git_control && ! -s $tmp/git-output ]]
cat >"$git_bin/git" <<'EOF'
#!/bin/sh
: >"$GIT_MARKER"
exit 1
EOF
chmod +x "$git_bin/git"
: >"$tmp/empty.jsonl"
GIT_MARKER="$tmp/git-called" PATH="$git_bin:$PATH" SHELLFISH_SESSION="$tmp/empty.jsonl" \
  zsh -f "$git_prompt" user_prompt_submit 3>"$git_control" >/dev/null
[[ ! -e $tmp/git-called ]]

# Ordered command hooks leave ordinary and multiline prompts untouched.
typeset command_session="$tmp/command.jsonl" command_stream="$tmp/command.stream"
jq -c --arg root "$ROOT/share/hooks/" '.profile.hooks = {user_prompt_submit:
  (["help","verbose","new","resume","server","copy","sandbox","user_shell"] |
    map($root + .))}' < <(head -n 1 "$tmp/startup.jsonl") >"$tmp/command-header"
submit() {
  cp "$tmp/command-header" "$command_session"
  sf_test_run "$1" "$command_session" >"$command_stream"
}
for prompt in ordinary $'/help\nordinary'; do
  submit "$prompt"
  jq -e -s --arg prompt "$prompt" 'map(.type) == ["session","user","assistant"] and
    .[1].content[0].text == $prompt' "$command_session" >/dev/null
done
for prompt in /help /h; do
  submit "$prompt"
  jq -e -s 'map(.type) == ["session","hook_result"] and
    .[1].user_preview_lines == "full" and (.[1].user_text | contains("/quit, /q"))' \
    "$command_session" >/dev/null
done
for prompt in /new /resume /server /verbose /v; do
  submit "$prompt"
  jq -e -s --arg prompt "$prompt" --arg executable "$ROOT/bin/shellfish" \
    --arg session "${command_session:A}" '
    map(select(.type == "_handoff") | .argv) == [
      if $prompt == "/new" then [$executable,"--session-from",$session]
      elif $prompt == "/resume" then [$executable,"--resume"]
      elif $prompt == "/server" then ["shellfish-server","--session",$session]
      else [$executable,"--verbose","--clear","--session",$session] end]
  ' "$command_stream" >/dev/null || fail "$prompt handoff: $(<$command_stream)"
  [[ $(wc -l <"$command_session") -eq 1 ]]
done
SHELLFISH_VERBOSE=1 submit /verbose
jq -e -s --arg session "${command_session:A}" 'map(select(.type == "_handoff") | .argv[1:]) ==
  [["--clear","--session",$session]]' "$command_stream" >/dev/null
submit '!printf '\''${output.stderr}'\''; exit 7'
jq -e -s 'map(.type) == ["session","hook_result"] and
  (.[1].model_text | contains("${output.stderr}") and contains("(exit 7)")) and
  (.[1].user_text | startswith("Shell command:\n$ "))' "$command_session" >/dev/null
for prompt in '! ' '/copy 0'; do
  submit "$prompt"
  jq -e -s 'map(.type) == ["session","hook_result"] and
    (.[1].user_text | startswith("usage: ")) and (.[1] | has("model_text") | not)' \
    "$command_session" >/dev/null
done
