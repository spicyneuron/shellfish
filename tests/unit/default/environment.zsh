#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-environment

# The model context a bundled hook settles on fd 3, or nothing.
settled() { jq -rs 'map(select(has("model_final"))) | last.model_final // ""' "$1"; }

# Report project environment as context after a draft.
typeset environment_control="$tmp/environment-control.json"
typeset environment_script="$ROOT/share/profiles/default/hooks/session_start/project_environment/run"
typeset environment_bin="$tmp/environment-bin"
typeset environment_output
mkdir "$environment_bin"
cat >"$environment_bin/tree" <<'EOF'
#!/bin/sh
printf '.\n'
EOF
chmod +x "$environment_bin/tree"
PATH="$environment_bin:$PATH" zsh -f "$environment_script" session_start \
  3>"$environment_control" >/dev/null
jq -e -s '.[0] | has("user_draft")' "$environment_control" >/dev/null
environment_output=$(settled "$environment_control")
[[ $environment_output == '<context script="project_environment">'$'\n'*$'\n</context>' ]]
[[ $environment_output == *$'PWD: '*$'\n.'* ]]
[[ $environment_output == *'Available commands:'* ]]
[[ $environment_output == *'Available agent skills.'* ]]
[[ $environment_output == *'- skill-creator: '* ]]
[[ $environment_output != *'Git '* ]]
cat >"$environment_bin/tree" <<'EOF'
#!/bin/sh
exit 124
EOF
PATH="$environment_bin:$PATH" zsh -f "$environment_script" session_start \
  3>"$environment_control" >/dev/null
environment_output=$(settled "$environment_control")
[[ $environment_output == *'Filesystem context: (skipped, slow file system)'* ]]
[[ $environment_output == *'Available commands:'* ]]
[[ $environment_output == *'Available agent skills.'* ]]

# Record Git identity transitions.
typeset git_start="$ROOT/share/profiles/default/hooks/session_start/git_environment/run"
typeset git_prompt="$ROOT/share/profiles/default/hooks/user_prompt_submit/git_environment/run"
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
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$git_bin/git"
print -r -- 'branch:main' >"$git_state"
PATH="$git_bin:$PATH" GIT_STATE="$git_state" \
  zsh -f "$git_start" session_start 3>"$git_control"
git_output=$(settled "$git_control")
[[ $git_output == *main* && $git_output == *'abc123 Test commit'* &&
   $git_output == *status-file* && $git_output != *'Recent files:'* ]]
jq -e -s 'last.state == [{name:"git/identity",value:"branch:main"}]' \
  "$git_control" >/dev/null
jq -c '.state[]? | {type:"state"} + .' "$git_control" >"$git_session"
print -r -- '{"type":"state","name":"git/other","value":"ignored"}' >>"$git_session"

PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION="$git_session" \
  zsh -f "$git_prompt" user_prompt_submit 3>"$git_control"
git_output=$(settled "$git_control")
assert_equal '' "$git_output"
[[ ! -s $git_control ]]
print -r -- 'branch:feature' >"$git_state"
PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION="$git_session" \
  zsh -f "$git_prompt" user_prompt_submit 3>"$git_control"
git_output=$(settled "$git_control")
[[ $git_output == *main* && $git_output == *feature* ]]
jq -e -s 'last.state == [{name:"git/identity",value:"branch:feature"}]' \
  "$git_control" >/dev/null
jq -c '.state[]? | {type:"state"} + .' "$git_control" >>"$git_session"
PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION="$git_session" \
  zsh -f "$git_prompt" user_prompt_submit 3>"$git_control"
git_output=$(settled "$git_control")
assert_equal '' "$git_output"
[[ ! -s $git_control ]]

print -r -- 'commit:0123456789abcdef' >"$git_state"
PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION="$git_session" \
  zsh -f "$git_prompt" user_prompt_submit 3>"$git_control"
git_output=$(settled "$git_control")
[[ $git_output == *feature* && $git_output == *0123456789abcdef* ]]
jq -e -s 'last.state == [{name:"git/identity",value:"commit:0123456789abcdef"}]' \
  "$git_control" >/dev/null
jq -c '.state[]? | {type:"state"} + .' "$git_control" >>"$git_session"

cat >"$git_bin/git" <<'EOF'
#!/bin/sh
exit 124
EOF
chmod +x "$git_bin/git"
PATH="$git_bin:$PATH" SHELLFISH_SESSION="$git_session" \
  zsh -f "$git_prompt" user_prompt_submit 3>"$git_control"
git_output=$(settled "$git_control")
assert_equal '' "$git_output"
[[ ! -s $git_control ]]

PATH="$git_bin:$PATH" zsh -f "$git_start" session_start 3>"$git_control"
assert_equal '' "$(settled "$git_control")"
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
