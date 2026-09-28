#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/jq.zsh
sf_test_tmp skills
source "$ROOT/share/lib/skills.zsh"

tool="$ROOT/share/tools/skill/run"
project="$tmp/project"
config="$tmp/config/shellfish"
home="$tmp/home"
mkdir -p "$project/.agents/skills" "$config/skills" "$home/.agents/skills"

make_skill() {
  local root=$1 name=$2 description=$3 disabled=${4:-false}
  mkdir -p "$root/$name"
  cat >"$root/$name/SKILL.md" <<EOF
---
name: $name
description: $description
disable-model-invocation: $disabled
license: test
---

# $name instructions
EOF
}

make_skill "$home/.agents/skills" shared 'home description'
make_skill "$config/skills" shared 'config description'
make_skill "$project/.agents/skills" shared 'project description'
make_skill "$config/skills" config-only 'configured skill'
make_skill "$home/.agents/skills" personal 'personal skill'
make_skill "$tmp/linked-skills" linked 'linked skill'
ln -s "$tmp/linked-skills/linked" "$config/skills/linked"
make_skill "$project/.agents/skills" hidden 'must not be advertised' true
make_skill "$project/.agents/skills" bad_name 'invalid skill'
make_skill "$project/.claude/skills" claude-only 'must be ignored'

# Discover valid skills by precedence.
HOME="$home" sf_skills_discover "$ROOT/share" "$config" "$project"
typeset -A descriptions skill_paths
integer index
for (( index = 1; index <= ${#reply}; index += 3 )); do
  descriptions[$reply[index]]=$reply[index+1]
  skill_paths[$reply[index]]=$reply[index+2]
done
[[ $descriptions[shared] == 'project description' ]]
[[ $skill_paths[shared] == "${project:A}/.agents/skills/shared/SKILL.md" ]]
[[ $descriptions[config-only] == 'configured skill' ]]
[[ $descriptions[personal] == 'personal skill' ]]
[[ $descriptions[linked] == 'linked skill' ]]
[[ $skill_paths[linked] == "${tmp:A}/linked-skills/linked/SKILL.md" ]]
[[ -n ${descriptions[skill-creator]-} ]]
[[ -z ${descriptions[hidden]-} && -z ${descriptions[bad_name]-} ]]
[[ -z ${descriptions[claude-only]-} ]]
HOME="$home" sf_skills_discover "$ROOT/share" "$config" "$project" true
[[ ${reply[(Ie)hidden]} -gt 0 ]]

# Fall back to Claude skills when the project has no Agent Skills directory.
claude_project="$tmp/claude-project"
make_skill "$claude_project/.claude/skills" shared 'claude project description'
HOME="$home" sf_skills_discover "$ROOT/share" "$config" "$claude_project"
typeset -A claude_descriptions claude_paths
for (( index = 1; index <= ${#reply}; index += 3 )); do
  claude_descriptions[$reply[index]]=$reply[index+1]
  claude_paths[$reply[index]]=$reply[index+2]
done
[[ $claude_descriptions[shared] == 'claude project description' ]]
[[ $claude_paths[shared] == "${claude_project:A}/.claude/skills/shared/SKILL.md" ]]

# Load only valid advertised skills.
loaded=$(cd "$project" && print -rn -- '{"name":"shared"}' | HOME="$home" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "<skill name=\"shared\" directory=\"${project:A}/.agents/skills/shared\">"*$'# shared instructions'*'</skill>' ]]
[[ $loaded != *$'\nname: shared\n'* ]]
loaded=$(cd "$claude_project" && print -rn -- '{"name":"shared"}' | HOME="$home" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "<skill name=\"shared\" directory=\"${claude_project:A}/.claude/skills/shared\">"*$'# shared instructions'*'</skill>' ]]
loaded=$(cd "$project" && print -rn -- '{"name":"skill-creator"}' | HOME="$home" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "<skill name=\"skill-creator\" directory=\"$ROOT/share/skills/skill-creator\">"*'</skill>' ]]
[[ $loaded != *$'\ndescription: Use when creating or editing project-local skills.\n'* ]]
loaded=$(cd "$project" && print -rn -- '{"name":"linked"}' | HOME="$home" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "<skill name=\"linked\" directory=\"${tmp:A}/linked-skills/linked\">"*$'# linked instructions'*'</skill>' ]]
make_skill "$tmp/odd & \"root\"" odd 'odd description'
sf_skills_body "$tmp/odd & \"root\"/odd/SKILL.md"
loaded=$(sf_skills_wrap odd "$tmp/odd & \"root\"/odd" "$REPLY")
[[ $loaded == *'directory="'*'odd &amp; &quot;root&quot;/odd">'* ]]
[[ $loaded != *'description: odd description'* ]]
if (cd "$project" && print -rn -- '{"name":"hidden"}' | HOME="$home" \
    SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool" >/dev/null 2>&1); then
  fail 'skill tool loaded a model-disabled skill'
fi

# Prompt references load each valid skill once, including user-only skills.
sf_test_frozen_profile
SF_TEST_PROFILE=$(jq -c --arg hook "$ROOT/share/hooks/skills" \
  '.hooks.user_prompt_submit=[$hook]' <<<"$SF_TEST_PROFILE")
session="$tmp/skills.jsonl"
(cd "$project" && sf_test_session "$session")
control="$tmp/prompt-skills.json"
HOME="$home" SHELLFISH_CONFIG_DIR="$config" sf_test_run \
  'Use $shared and $config-only, then $shared. Ignore $hidden, $missing, and foo$personal.' \
  "$session" >"$control"
jq -e -s '
  map(select(.type == "hook_result")) | length == 1 and
  (.[0].user_text | startswith("Loaded $shared:\n# shared instructions")) and
  (.[0].user_text | contains("# shared instructions")) and
  (.[0].user_text | contains("<skill") | not) and
  (.[0].model_text | contains("<skill name=\"shared\" directory=\"")) and
  (.[0].model_text | contains("# shared instructions")) and
  (.[0].model_text | contains("description: project description") | not) and
  (.[0].user_text | contains("Loaded $config-only:\n# config-only instructions")) and
  (.[0].user_text | contains("Loaded $hidden:\n# hidden instructions")) and
  (.[0].model_text | [scan("<context script=\"skills\">")] | length == 3) and
  (.[0].model_text | [scan("# shared instructions")] | length == 1) and
  (.[0].model_text | contains("# config-only instructions") and contains("# hidden instructions"))
' "$control" >/dev/null
for prompt in 'No skill here' '$missing'; do
  HOME="$home" SHELLFISH_CONFIG_DIR="$config" sf_test_run "$prompt" "$session" >"$control"
  jq -e -s 'all(.[]; .type != "hook_result")' "$control" >/dev/null
done
