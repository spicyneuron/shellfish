#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp skills
source "$ROOT/share/default/lib/skills.zsh"

tool="$ROOT/share/default/tools/skill/run"
project="$tmp/project"
config="$tmp/config"
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
make_skill "$project/.agents/skills" hidden 'must not be advertised' true
make_skill "$project/.agents/skills" bad_name 'invalid skill'

HOME="$home" sf_skills_discover "$ROOT/share/default" "$config" "$project"
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
[[ -n ${descriptions[skill-creator]-} ]]
[[ -z ${descriptions[hidden]-} && -z ${descriptions[bad_name]-} ]]

loaded=$(print -rn -- '{"name":"shared"}' | HOME="$home" PROJECT_DIR="$project" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "Skill directory: ${project:A}/.agents/skills/shared"*$'# shared instructions'* ]]
loaded=$(print -rn -- '{"name":"skill-creator"}' | HOME="$home" PROJECT_DIR="$project" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "Skill directory: $ROOT/share/default/skills/skill-creator"*$'\nname: skill-creator\n'* ]]
if print -rn -- '{"name":"hidden"}' | HOME="$home" PROJECT_DIR="$project" \
    SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool" >/dev/null 2>&1; then
  fail 'skill tool loaded a model-disabled skill'
fi
if print -rn -- '{"name":"missing","extra":true}' | HOME="$home" PROJECT_DIR="$project" \
    SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool" >/dev/null 2>&1; then
  fail 'skill tool accepted invalid input'
fi
