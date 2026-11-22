#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/jq.zsh
sf_test_tmp skills
source "$ROOT/share/lib/skills.zsh"

tool="$ROOT/share/tools/skill/run"
project="$tmp/project"
home="$tmp/home"
config="$home/.shellfish"
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

sf_test_frozen_profile
session="$tmp/discovery.jsonl"
(cd "$project" && sf_test_session "$session")
export SHELLFISH_SESSION="$session"

# Discover valid skills by precedence.
HOME="$home" sf_skills_discover "$config" "$project"
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
[[ -z ${descriptions[hidden]-} && -z ${descriptions[bad_name]-} ]]
[[ -z ${descriptions[claude-only]-} ]]
HOME="$home" sf_skills_discover "$config" "$project" true
[[ ${reply[(Ie)hidden]} -gt 0 ]]

# Another .shellfish directory uses its own sibling .agents, not the home one.
flavor="$tmp/flavor"
make_skill "$flavor/.agents/skills" flavored 'flavor skill'
mkdir -p "$flavor/.shellfish"
HOME="$home" sf_skills_discover "$flavor/.shellfish" "$tmp/elsewhere"
(( ${#reply} == 3 ))
[[ $reply[3] == "${flavor:A}/.agents/skills/flavored/SKILL.md" ]]
# A Shellfish directory with another name has no sibling source.
mkdir -p "$flavor/custom"
HOME="$home" sf_skills_discover "$flavor/custom" "$tmp/elsewhere"
(( ${#reply} == 0 ))

# Load only valid advertised skills.
loaded=$(cd "$project" && print -rn -- '{"name":"shared"}' | HOME="$home" \
  SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool")
[[ $loaded == "<skill name=\"shared\" directory=\"${project:A}/.agents/skills/shared\">"*$'# shared instructions'*'</skill>' ]]
[[ $loaded != *$'\nname: shared\n'* ]]
HOME="$home" SHELLFISH_DIR="$config" "$ROOT/bin/shellfish" init >/dev/null
loaded=$(cd "$project" && print -rn -- '{"name":"skill-creator"}' | HOME="$home" \
  SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool")
[[ $loaded == "<skill name=\"skill-creator\" directory=\"${config:A}/skills/skill-creator\">"*'</skill>' ]]
[[ $loaded != *$'\ndescription: Use when creating or editing project-local skills.\n'* ]]
loaded=$(cd "$project" && print -rn -- '{"name":"linked"}' | HOME="$home" \
  SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool")
[[ $loaded == "<skill name=\"linked\" directory=\"${tmp:A}/linked-skills/linked\">"*$'# linked instructions'*'</skill>' ]]
make_skill "$tmp/odd & \"root\"" odd 'odd description'
sf_skills_body "$tmp/odd & \"root\"/odd/SKILL.md"
loaded=$(sf_skills_wrap odd "$tmp/odd & \"root\"/odd" "$REPLY")
[[ $loaded == *'directory="'*'odd &amp; &quot;root&quot;/odd">'* ]]
[[ $loaded != *'description: odd description'* ]]
if (cd "$project" && print -rn -- '{"name":"hidden"}' | HOME="$home" \
    SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool" >/dev/null 2>&1); then
  fail 'skill tool loaded a model-disabled skill'
fi
listed=$(cd "$project" && HOME="$home" SHELLFISH_DIR="$config" SHELLFISH_SHARE_DIR="$ROOT/share" \
  SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$ROOT/share/hooks/skills/list/run" 2>/dev/null)
[[ $listed == *'- shared:'* && $listed != *hidden* ]] || fail "skill list exposed a user-only skill: $listed"

# /skill stages an allowed skill for the next prompt, even if it is user-only.
sf_test_frozen_profile
SF_TEST_PROFILE=$(jq -c --arg command "$ROOT/share/commands/user_skill" '.commands=[$command]' \
  <<<"$SF_TEST_PROFILE")
control="$tmp/command.jsonl"
skill_command() {
  session="$tmp/command-session.jsonl"
  (cd "$project" && sf_test_session "$session")
  HOME="$home" SHELLFISH_DIR="$config" sf_test_run "$1" "$session" >"$control"
}
skill_command $'/skill\thidden \n'
jq -e -s '
  map(.type) == ["session","hook_result"] and .[1].action == "deny" and
  .[1].user_text == "**Loaded skill** hidden" and
  (.[1].model_content[0].text | startswith("<context script=\"user_skill\">\n<skill name=\"hidden\"") and
    contains("# hidden instructions") and (contains("description:") | not))
' "$session" >/dev/null || fail '/skill did not stage a user-only skill'
skill_error() {
  skill_command "$1"
  jq -e -s --arg message "$2" 'map(.type) == ["session","hook_result"] and .[1].action == "deny" and
    (.[1].user_text | rtrimstr("\n")) == $message and
    (.[1] | has("model_content") | not)' "$session" >/dev/null ||
    fail "/skill did not withhold the prompt and show: $2"
}
skill_error /skill 'usage: /skill NAME'
skill_error $'/skill hidden\treview\nthis diff' 'usage: /skill NAME'
skill_error '/skill missing' 'skill is not available: missing'

# Compaction hands off the next prompt as a draft. Sending it in the compacted
# session should deliver the staged skill once without rerunning the command.
(
  export HOME="$home" SHELLFISH_DIR="$config"
  sf_test_hook "$tmp/summary-provider" <<'ZSH'
#!/bin/zsh
cat >"${0:h}/request.json"
print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"Acknowledged."}]}'
ZSH
  SF_TEST_PROFILE=$(jq -c --arg hook "$ROOT/share/hooks/autocompact" '.hooks=[$hook]' \
    <<<"$SF_TEST_PROFILE")
  SF_TEST_MODEL=$(jq -c --arg provider "$tmp/summary-provider" \
    '.provider=$provider | .context_window=100' <<<"$SF_TEST_MODEL")
  session="$tmp/skill-compaction.jsonl"
  (cd "$project" && sf_test_session "$session")
  jq -cn '
    {type:"user",section:1,content:[{type:"text",text:"First task"}]},
    {type:"assistant",section:2,stop:"end",content:[]},
    {type:"user",section:3,content:[{type:"text",text:("Recent task " + ("x" * 82000))}]},
    {type:"assistant",section:4,stop:"end",content:[],usage:{input_tokens:80,output_tokens:2}}
  ' >>"$session"
  sf_test_run '/skill hidden' "$session" >"$control"
  jq -e -s 'map(.type) == ["hook_result"] and .[0].action == "deny"' "$control" >/dev/null ||
    fail '/skill ran submission hooks or inference'

  prompt='Review this diff'
  sf_test_run "$prompt" "$session" >"$control"
  child=$(jq -er --arg prompt "$prompt" \
    'select(.type == "_handoff" and .argv[-2:] == ["--draft",$prompt]) | .argv[2]' "$control") ||
    fail 'autocompact did not hand off the next prompt'
  sf_test_run "$prompt" "$child" >"$control"
  jq -e --arg prompt "$prompt" '
    .messages[-1].content | map(.text) | join("") |
    endswith($prompt) and ([scan("# hidden instructions")] | length == 1)
  ' "$tmp/summary-provider/request.json" >/dev/null ||
    fail 'the next prompt did not receive exactly one copy of the staged skill'
)

# The frozen allowlist applies to the tool from every source.
SF_TEST_PROFILE=$(jq -c '.config.skills=["shared","personal","hidden","missing","shared"]' \
  <<<"$SF_TEST_PROFILE")
session="$tmp/filtered.jsonl"
(cd "$project" && sf_test_session "$session")
export SHELLFISH_SESSION="$session"
for name in shared personal; do
  loaded=$(cd "$project" && print -rn -- "{\"name\":\"$name\"}" | HOME="$home" \
    SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool")
  [[ $loaded == *"# $name instructions"* ]]
done
[[ $loaded == *"directory=\"${home:A}/.agents/skills/personal\""* ]]
for name in config-only hidden skill-creator missing; do
  if (cd "$project" && print -rn -- "{\"name\":\"$name\"}" | HOME="$home" \
      SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool" >/dev/null); then
    fail "skill tool loaded an unavailable skill: $name"
  fi
done

SF_TEST_PROFILE=$(jq -c '.config.skills=[]' <<<"$SF_TEST_PROFILE")
skill_error '/skill hidden' 'skill is not available: hidden'
session="$tmp/no-skills.jsonl"
(cd "$project" && sf_test_session "$session")
export SHELLFISH_SESSION="$session"
if (cd "$project" && print -rn -- '{"name":"shared"}' | HOME="$home" \
    SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool" >/dev/null); then
  fail 'an empty allowlist allowed tool loading'
fi

for value in null false 1 '"shared"' '{}' '[null]' '[1]' '["bad_name"]' '["*"]' \
    '["shared\n"]' '["abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklm"]'; do
  SF_TEST_PROFILE=$(jq -c --argjson value "$value" '.config.skills=$value' <<<"$SF_TEST_PROFILE")
  session="$tmp/invalid.jsonl"
  (cd "$project" && sf_test_session "$session")
  export SHELLFISH_SESSION="$session"
  if (cd "$project" && print -rn -- '{"name":"shared"}' | HOME="$home" \
      SHELLFISH_DIR="$config" SHELLFISH_CONFIG="$(sf_test_session_config "$session")" zsh -f "$tool" >"$tmp/invalid.out" 2>"$tmp/invalid.err"); then
    fail "skill tool accepted invalid config.skills: $value"
  fi
  grep -q 'config.skills must be an array of skill names' "$tmp/invalid.err"
done
