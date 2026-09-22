#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp skills
source "$ROOT/share/default/lib/skills.zsh"

tool="$ROOT/share/default/tools/skill/run"
project="$tmp/project"
config="$tmp/config"
home="$tmp/home"
xdg="$tmp/xdg"
mkdir -p "$project/.agents/skills" "$config/skills" "$home/.agents/skills" \
  "$xdg/shellfish/skills"

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
make_skill "$tmp/linked-skills" user-config 'user config skill'
ln -s "$tmp/linked-skills/user-config" "$xdg/shellfish/skills/user-config"
make_skill "$project/.agents/skills" hidden 'must not be advertised' true
make_skill "$project/.agents/skills" bad_name 'invalid skill'
make_skill "$project/.claude/skills" claude-only 'must be ignored'

# Discover valid skills by precedence.
HOME="$home" XDG_CONFIG_HOME="$xdg" sf_skills_discover "$ROOT/share/default" "$config" "$project"
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
[[ $descriptions[user-config] == 'user config skill' ]]
[[ -n ${descriptions[skill-creator]-} ]]
[[ -z ${descriptions[hidden]-} && -z ${descriptions[bad_name]-} ]]
[[ -z ${descriptions[claude-only]-} ]]

# Fall back to Claude skills when the project has no Agent Skills directory.
claude_project="$tmp/claude-project"
make_skill "$claude_project/.claude/skills" shared 'claude project description'
HOME="$home" sf_skills_discover "$ROOT/share/default" "$config" "$claude_project"
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
[[ $loaded == "Skill directory: ${project:A}/.agents/skills/shared"*$'# shared instructions'* ]]
loaded=$(cd "$claude_project" && print -rn -- '{"name":"shared"}' | HOME="$home" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "Skill directory: ${claude_project:A}/.claude/skills/shared"*$'# shared instructions'* ]]
loaded=$(cd "$project" && print -rn -- '{"name":"skill-creator"}' | HOME="$home" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "Skill directory: $ROOT/share/default/skills/skill-creator"*$'\nname: skill-creator\n'* ]]
loaded=$(cd "$project" && print -rn -- '{"name":"linked"}' | HOME="$home" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "Skill directory: ${tmp:A}/linked-skills/linked"*$'# linked instructions'* ]]
loaded=$(cd "$project" && print -rn -- '{"name":"user-config"}' | HOME="$home" \
  XDG_CONFIG_HOME="$xdg" SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "Skill directory: ${tmp:A}/linked-skills/user-config"*$'# user-config instructions'* ]]
if (cd "$project" && print -rn -- '{"name":"hidden"}' | HOME="$home" \
    SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool" >/dev/null 2>&1); then
  fail 'skill tool loaded a model-disabled skill'
fi
