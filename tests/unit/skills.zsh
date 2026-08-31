#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp skills

hook="$ROOT/default/hooks/session_start/add_skills"
tool="$ROOT/default/tools/skill/run"
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

output=$(HOME="$home" PROJECT_DIR="$project" SHELLFISH_CONFIG_DIR="$config" \
  zsh -f "$hook" session_start)
[[ $output == *'- shared: project description'* ]]
[[ $output == *'- config-only: configured skill'* ]]
[[ $output == *'- personal: personal skill'* ]]
[[ $output != *'home description'* && $output != *hidden* && $output != *bad_name* ]]

loaded=$(print -rn -- '{"name":"shared"}' | HOME="$home" PROJECT_DIR="$project" \
  SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool")
[[ $loaded == "Skill directory: ${project:A}/.agents/skills/shared"*$'# shared instructions'* ]]
if print -rn -- '{"name":"hidden"}' | HOME="$home" PROJECT_DIR="$project" \
    SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool" >/dev/null 2>&1; then
  fail 'skill tool loaded a model-disabled skill'
fi
if print -rn -- '{"name":"missing","extra":true}' | HOME="$home" PROJECT_DIR="$project" \
    SHELLFISH_CONFIG_DIR="$config" zsh -f "$tool" >/dev/null 2>&1; then
  fail 'skill tool accepted invalid input'
fi
