#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-environment

# The suite runs files concurrently, where a first fork can cost most of the
# probe budget. Raise it so these cases assert hook output rather than load.
export SHELLFISH_PROBE_BUDGET=30

# Short bundled probes preserve command results and share an absolute deadline.
(
  source "$ROOT/share/default/lib/capped.zsh"
  zmodload zsh/datetime
  typeset -F capped_deadline
  integer capped_status=0
  setopt bg_nice
  capped_deadline=$(( EPOCHREALTIME + 1 ))
  assert_equal 'probe output' "$(sf_capped "$capped_deadline" printf 'probe output')"
  sf_capped "$capped_deadline" sh -c 'exit 7' || capped_status=$?
  assert_equal 7 "$capped_status"
  capped_status=0
  sf_capped "$capped_deadline" sh -c 'exit 143' || capped_status=$?
  assert_equal 143 "$capped_status"
  [[ $options[bgnice] == on ]]
  capped_deadline=$(( EPOCHREALTIME + 0.05 ))
  capped_status=0
  sf_capped "$capped_deadline" sleep 1 || capped_status=$?
  assert_equal 124 "$capped_status"
  capped_status=0
  sf_capped "$capped_deadline" sh -c ': >"$1"' _ "$tmp/capped-called" || capped_status=$?
  assert_equal 124 "$capped_status"
  [[ ! -e $tmp/capped-called ]]
)

typeset environment_script="$ROOT/share/default/hooks/session_start/project_environment"
typeset environment_bin="$tmp/environment-bin"
typeset environment_output
mkdir "$environment_bin"
cat >"$environment_bin/tree" <<'EOF'
#!/bin/sh
printf '.\n'
EOF
chmod +x "$environment_bin/tree"
environment_output=$(PATH="$environment_bin:$PATH" zsh -f "$environment_script" session_start)
[[ $environment_output == *$'PWD: '*$'\n.'* ]]
[[ $environment_output == *'Available commands:'* ]]
[[ $environment_output == *'Available agent skills.'* ]]
[[ $environment_output == *'- skill-creator: '* ]]
[[ $environment_output != *'Git '* ]]
cat >"$environment_bin/tree" <<'EOF'
#!/bin/sh
exit 124
EOF
environment_output=$(PATH="$environment_bin:$PATH" zsh -f "$environment_script" session_start)
[[ $environment_output == *'Filesystem context: (skipped, slow file system)'* ]]
[[ $environment_output == *'Available commands:'* ]]
[[ $environment_output == *'Available agent skills.'* ]]

# git_environment establishes state only after a fast, successful startup probe.
# Later prompt probes report each branch or detached-commit transition once.
typeset git_start="$ROOT/share/default/hooks/session_start/git_environment"
typeset git_prompt="$ROOT/share/default/hooks/user_prompt_submit/git_environment"
typeset git_bin="$tmp/git-environment-bin" git_state="$tmp/git-state"
typeset git_cache="$tmp/git_environment" git_output
mkdir "$git_bin"
cat >"$git_bin/git" <<'EOF'
#!/bin/sh
IFS= read -r state <"$GIT_STATE" || state=
case "$1:$2" in
  rev-parse:--verify) printf '%s\n' "${state#commit:}" ;;
  log:--oneline) printf 'abc123 Test commit\n' ;;
  log:--name-status) printf 'M\tchanged-log-file\n' ;;
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
git_output=$(PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_start" session_start)
[[ $git_output == *main* && $git_output == *'abc123 Test commit'* &&
   $git_output == *changed-log-file* && $git_output == *status-file* ]]
assert_equal 'branch:main' "$(<$git_cache)"

git_output=$(PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_prompt" user_prompt_submit)
assert_equal '' "$git_output"
print -r -- 'branch:feature' >"$git_state"
git_output=$(PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_prompt" user_prompt_submit)
[[ $git_output == *main* && $git_output == *feature* ]]
assert_equal 'branch:feature' "$(<$git_cache)"
git_output=$(PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_prompt" user_prompt_submit)
assert_equal '' "$git_output"

print -r -- 'commit:0123456789abcdef' >"$git_state"
git_output=$(PATH="$git_bin:$PATH" GIT_STATE="$git_state" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_prompt" user_prompt_submit)
[[ $git_output == *feature* && $git_output == *0123456789abcdef* ]]
assert_equal 'commit:0123456789abcdef' "$(<$git_cache)"

cat >"$git_bin/git" <<'EOF'
#!/bin/sh
exit 124
EOF
chmod +x "$git_bin/git"
git_output=$(PATH="$git_bin:$PATH" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_prompt" user_prompt_submit)
assert_equal '' "$git_output"
assert_equal 'commit:0123456789abcdef' "$(<$git_cache)"

rm -f "$git_cache"
cat >"$git_bin/git" <<'EOF'
#!/bin/sh
exit 124
EOF
chmod +x "$git_bin/git"
git_output=$(PATH="$git_bin:$PATH" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_start" session_start)
assert_equal '' "$git_output"
[[ ! -e $git_cache ]]
cat >"$git_bin/git" <<'EOF'
#!/bin/sh
: >"$GIT_MARKER"
exit 1
EOF
chmod +x "$git_bin/git"
GIT_MARKER="$tmp/git-called" PATH="$git_bin:$PATH" SHELLFISH_SESSION_STATE="$tmp" \
  zsh -f "$git_prompt" user_prompt_submit >/dev/null
[[ ! -e $tmp/git-called ]]

# Shell command reporting is best-effort and selects the first candidate with a
# usable version within the combined project environment context.
typeset shell_commands_bin="$tmp/shell-commands-bin"
typeset shell_commands_output shell_commands_rows
mkdir "$shell_commands_bin"
ln -s "${commands[zsh]:A}" "$shell_commands_bin/zsh"
for name in date uname head; do
  ln -s "${commands[$name]:A}" "$shell_commands_bin/$name"
done
make_version_command() {
  local name=$1 body=$2
  print -r -- '#!/bin/sh' >"$shell_commands_bin/$name"
  print -r -- "$body" >>"$shell_commands_bin/$name"
  chmod +x "$shell_commands_bin/$name"
}
make_version_command rg 'exit 2'
make_version_command grep "printf 'grep 1.0\\nignored\\n'"
make_version_command find 'exit 2'
make_version_command what "printf 'archive PROGRAM:find  PROJECT:find-2.1 other\\n'"
make_version_command tree "printf 'tree v2.3.2-beta+build456 © 1996 Example\\n'"
make_version_command jq "printf 'jq-1.7\\n'"
make_version_command yq "printf 'yq 01.2.3, 1.2.3.4, and 1.2.3+ are invalid semver\\n'"
make_version_command python3 "printf 'Python 3.13\\n' >&2"
make_version_command git "printf 'git version 2.48\\n'"
make_version_command gh 'exit 0'

shell_commands_output=$(
  /usr/bin/env PATH="$shell_commands_bin" "$shell_commands_bin/zsh" -f \
    "$environment_script" session_start
)
[[ $shell_commands_output == *"$ZSH_VERSION"* ]]
shell_commands_rows=$(jq -Rsc '
  [split("\n")[] |
    capture("^- [^:]+: (?<command>[^ ]+) \\((?<version>.*)\\)$")?] |
  INDEX(.command)
' <<<"$shell_commands_output") || fail 'cannot parse shell commands output'
jq -e '
  length == 7 and
  .grep.version == "grep 1.0" and
  .find.version == "find-2.1" and
  .tree.version == "2.3.2-beta+build456" and
  .jq.version == "jq-1.7" and
  .yq.version == "yq 01.2.3, 1.2.3.4, and 1.2.3+ are invalid semver" and
  .python3.version == "Python 3.13" and
  .git.version == "git version 2.48" and
  (has("gh") | not)
' <<<"$shell_commands_rows" >/dev/null
