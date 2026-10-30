#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-environment

# Model context emitted by the Git checkout prompt hook.
settled() { jq -rs 'map(select(.type == "hook_result")) | last.model_text // ""' "$1"; }

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
typeset git_prompt="$ROOT/share/hooks/git/identity/run"
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
"$ROOT/bin/shellfish" init >/dev/null
sf_test_model default "{\"provider\":\"$ROOT/tests/fixtures/provider\",\"request\":{\"model\":\"test\"}}"
sf_test_profile default '{
  "system": ["general.md", "tools.md"],
  "tools": ["read_file", "edit_file", "write_file", "skill", "search_web", "fetch_url", "shell"],
  "hooks": ["project/environment", "git/environment", "project/instructions", "skills/list",
    "git/identity"]
}'
startup() {
  rm -f "$tmp/startup.jsonl"
  PATH="$environment_bin:$git_bin:$PATH" GIT_STATE="$git_state" \
    "$ROOT/bin/shellfish" run --jsonl --session-create --session-out "$tmp/startup.jsonl" \
    --profile "${1:-default}" >"$tmp/startup.stream" || return
  assert_canonical_session "$tmp/startup.jsonl"
}
startup
jq -e -s '
  [ .[] | select(.type == "state_update" or .type == "hook_result") ] as $results |
  ($results | map(.type)) ==
    ["hook_result","state_update","hook_result","hook_result","hook_result"] and
  ($results[0].user_text | startswith("**Project environment**\n")) and
  ($results[0].model_text | startswith("<context script=\"project/environment\">\n")) and
  ($results[0].model_text | contains("PWD: ") and contains("\n.") and
    contains("Available commands:") and (contains("Available agent skills.") | not) and
    (contains("Git ") | not)) and
  $results[1].name == "git/identity" and $results[1].value == "branch:main" and
  ($results[2].user_text | startswith("**Git environment**\nGit branch: main")) and
  ($results[2].model_text | startswith("<context script=\"git/environment\">\n") and
    contains("abc123 Test commit") and contains("status-file") and
    (contains("Recent files:") | not)) and
  ($results[4].model_text | startswith("<context script=\"skills/list\">\nAvailable agent skills.") and
    contains("- skill-creator: "))
' "$tmp/startup.jsonl" >/dev/null || fail 'default startup context or state ordering changed'
jq -c 'select(.type == "session" or .type == "state_update")' "$tmp/startup.jsonl" >"$git_session"
print -r -- '{"type":"state_update","name":"git/other","value":"ignored"}' >>"$git_session"
print -r -- $'#!/bin/sh\nexit 124' >"$environment_bin/tree"
print -r -- 'commit:0123456789abcdef' >"$git_state"
startup
jq -e -s 'any(.[]; .type == "state_update" and .value == "commit:0123456789abcdef") and
  any(.[]; (.user_text // "" | contains("(detached HEAD)"))) and
  any(.[]; (.model_text // "" | contains("Filesystem context: (skipped, slow file system)") and
    contains("Available commands:")))' \
  "$tmp/startup.jsonl" >/dev/null || fail 'detached startup context was lost'
print -r -- 'none' >"$git_state"
startup
jq -e -s 'all(.[]; .type != "state_update" and
  (.user_text // "" | startswith("**Git environment**") | not))' \
  "$tmp/startup.jsonl" >/dev/null || fail 'no-repository startup was not silent'
print -r -- 'branch:main' >"$git_state"

git_change() {
  PATH="$git_bin:$PATH" GIT_STATE="$git_state" \
    sf_test_run ordinary "$git_session" >"$git_control"
  git_output=$(settled "$git_control")
}
git_change
assert_equal '' "$git_output"
jq -e -s 'all(.[]; .type != "hook_result")' "$git_control" >/dev/null
print -r -- 'branch:feature' >"$git_state"
git_change
[[ $git_output == *main* && $git_output == *feature* ]]
[[ $git_output == '<context script="git/identity">'$'\n'*$'\n</context>' ]]
jq -e -s 'map(select(.type == "hook_result")) | last.user_text == "**Git checkout changed**\nmain → feature"' \
  "$git_control" >/dev/null
jq -e -s 'map(select(.type == "state_update")) | last.value == "branch:feature"' \
  "$git_control" >/dev/null
git_change
assert_equal '' "$git_output"
jq -e -s 'all(.[]; .type != "hook_result")' "$git_control" >/dev/null

print -r -- 'commit:0123456789abcdef' >"$git_state"
git_change
[[ $git_output == *feature* && $git_output == *0123456789abcdef* ]]
jq -e -s 'map(select(.type == "hook_result")) | last.user_text == "**Git checkout changed**\nfeature → detached commit 0123456789abcdef"' \
  "$git_control" >/dev/null
jq -e -s 'map(select(.type == "state_update")) | last.value == "commit:0123456789abcdef"' \
  "$git_control" >/dev/null

cat >"$git_bin/git" <<'EOF'
#!/bin/sh
exit 124
EOF
chmod +x "$git_bin/git"
git_change
assert_equal '' "$git_output"
jq -e -s 'all(.[]; .type != "hook_result")' "$git_control" >/dev/null

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

# Commands leave ordinary, multiline, and undeclared-argument prompts untouched.
typeset command_session="$tmp/command.jsonl" command_stream="$tmp/command.stream"
jq -c --arg root "$ROOT/share/" '
  .profile.commands = (["help","verbose","new","resume","server","copy","fork","sandbox","user_shell",
    "compact"] | map($root + "commands/" + .)) |
  .profile.hooks = [$root + "hooks/autocompact"]
' < <(head -n 1 "$tmp/startup.jsonl") >"$tmp/command-header"
submit() {
  cp "$tmp/command-header" "$command_session"
  sf_test_run "$1" "$command_session" >"$command_stream"
}
submit /h
jq -e -s 'map(.type) == ["session","hook_result"] and .[1].action == "deny" and
  (.[1].user_text | contains("/verbose, /v") and contains("/copy [N]") and
    contains("Summarize this session"))' "$command_session" >/dev/null ||
  fail 'help did not list profile commands'
submit '/copy x'
jq -e -s '(.[1].user_text | rtrimstr("\n")) == "usage: /copy [N]" and .[1].action == "deny"' \
  "$command_session" >/dev/null || fail 'command did not receive its arguments'
for prompt in ordinary $'/help\nordinary' '/new please'; do
  submit "$prompt"
  jq -e -s --arg prompt "$prompt" 'map(.type) == ["session","user","assistant"] and
    .[1].content[0].text == $prompt' "$command_session" >/dev/null
done
submit '/shell printf '\''${output.stderr}'\''; exit 7'
jq -e -s 'map(.type) == ["session","hook_result"] and
  (.[1].model_text | contains("The user ran this shell command:\n$ printf") and contains("${output.stderr}") and contains("(exit 7)")) and
  (.[1].user_text | startswith("**Shell** printf"))' "$command_session" >/dev/null
# Bundled sandbox policy distinguishes absolute and home-relative grants.
typeset sandbox="$ROOT/share/commands/sandbox/run" sandbox_session="$tmp/sandbox.jsonl"
mkdir -p "$tmp/project/dir" "$tmp/home/share"
jq -c --arg cwd "${tmp:A}/project" '.cwd=$cwd |
  .profile.sandbox={enabled:true, read:["@system"], write:[$cwd + "/dir","~/share"]}' \
  "$SF_TEST_SESSIONS/header_only.jsonl" >"$sandbox_session"
(
  builtin cd -- "$tmp/project"; export HOME="$tmp/home"
  call() {
    print -rn -- "${1#/sandbox }" | SHELLFISH_SESSION="$sandbox_session" SHELLFISH_SHARE_DIR="$ROOT/share" \
      zsh -f "$sandbox" 3>"$tmp/control" >/dev/null 2>&1 || fail 'sandbox hook failed'
    jq -rs 'last' "$tmp/control"
  }
  # A bundled grant matches by "@" or by its absolute path.
  [[ $(call "/sandbox +r $ROOT/share/system" | jq -r .action) == null ]] ||
    fail 'bundled grant duplicated'
  call "/sandbox -r $ROOT/share/system" | jq -e '.action == "session_update" and
    .profile.sandbox.read == []' >/dev/null || fail 'bundled grant removal by path failed'
  call '/sandbox -r @system' | jq -e '.action == "session_update" and
    .profile.sandbox.read == []' >/dev/null || fail 'bundled grant removal by @ failed'
  [[ $(call '/sandbox +w dir' | jq -r .action) == null ]] || fail 'absolute grant duplicated'
  [[ $(call '/sandbox +w ~/share' | jq -r .action) == null ]] || fail 'home grant duplicated'
  call '/sandbox -w dir' | jq -e '.action == "session_update" and
    .profile.sandbox.write == ["~/share"]' >/dev/null || fail 'absolute grant removal failed'
  call '/sandbox -w ~/share' | jq -e --arg path "${tmp:A}/project/dir" '
    .action == "session_update" and .profile.sandbox.write == [$path]' >/dev/null ||
    fail 'home grant removal failed'
)

# Startup advertises only allowlisted names and rejects invalid skill settings.
mkdir -p "$SF_TEST_CONFIG/skills/other"
print -r -- $'---\nname: other\ndescription: Other skill\n---\nOther instructions' \
  >"$SF_TEST_CONFIG/skills/other/SKILL.md"
sf_test_profile filtered '{"hooks":["skills/list"],
  "config":{"skills":["skill-creator","missing"]}}'
startup filtered
jq -e -s 'any(.[]; .type == "hook_result" and (.model_text |
  contains("- skill-creator:") and (contains("- other:") | not)))' \
  "$tmp/startup.jsonl" >/dev/null
sf_test_profile filtered '{"hooks":["skills/list"],"config":{"skills":[]}}'
startup filtered
jq -e -s 'all(.[]; (.model_text // "" | contains("Available agent skills.") | not))' \
  "$tmp/startup.jsonl" >/dev/null
sf_test_profile filtered '{"hooks":["skills/list"],"config":{"skills":null}}'
if startup filtered 2>"$tmp/skills.err"; then
  fail 'startup accepted invalid config.skills'
fi
grep -q 'config.skills must be an array of skill names' "$tmp/skills.err"
