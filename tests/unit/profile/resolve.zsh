#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

# A filter over lib/profile, with any further jq options.
profile_eval() {
  local filter=$1
  shift
  jq -L "$ROOT" -e "$@" 'include "lib/profile"; '"$filter"
}

# Profiles only select; model files only configure.
for profile in \
    '{"backend":{}}' '{"request":{}}' '{"env":{}}' '{"extend":["default"]}' \
    '{"model":1}' '{"model":[""]}' '{"sandbox":{"read":["relative"]}}' '{"hooks":{"stop":[]}}' \
    '{"tools":"read_file"}' '{"tools":[{}]}' '{"system":[{"text":1}]}' '{"themes":{}}'; do
  if print -r -- "$profile" | profile_eval 'config_profile(["p"])' >/dev/null 2>&1; then
    fail "invalid profile was accepted: $profile"
  fi
done
print -r -- '{"model":["a","@b/c.jsonc"],"sandbox":["~/s.jsonc"],"system":["x.md"],"tools":[],"hooks":["h"]}' |
  profile_eval 'config_profile(["p"])' >/dev/null
print -r -- '{"model":{"request":{}},"sandbox":[{"read":["./x"]}],"system":[{"text":"t"}]}' |
  profile_eval 'config_profile(["p"])' >/dev/null
for model in \
    '{"backend":"openai"}' '{"context_window":0}' '{"endpoint":"ftp://example.invalid"}' \
    '{"request":"x"}' '{"tools":[]}'; do
  if print -r -- "$model" | profile_eval 'config_model(["m"])' >/dev/null 2>&1; then
    fail "invalid model was accepted: $model"
  fi
done
print -r -- '{"context_window":null}' | profile_eval 'config_model(["m"])' >/dev/null

# Model items merge left to right: objects recursively, anything else replaced.
# The result needs a model and adapter.
profile_eval '
  model_merge([
    {"$schema":"x",adapter:"openai",request:{model:"base",reasoning:{effort:"low",budget:1},stop:["a"]}},
    {request:{reasoning:{effort:"high"},stop:["b"]},context_window:null},
    {adapter:"anthropic"}, {request:{seed:1}}
  ]) == {
    adapter:"anthropic",context_window:null,
    request:{model:"base",reasoning:{effort:"high",budget:1},stop:["b"],seed:1}
  }' -n >/dev/null || fail 'model files did not merge in order'
for models in '[{"adapter":"openai"}]' '[{"request":{"model":"m"}}]'; do
  if profile_eval 'model_merge($models)' -n --argjson models "$models" >/dev/null 2>&1; then
    fail "incomplete model was accepted: $models"
  fi
done

# Component lookup uses fixed kind directories.
sf_test_source lib/profile.zsh
sf_test_tmp resolve
sf_test_config
export HOME="$tmp/home"
typeset config="${SF_TEST_CONFIG:A}"
mkdir -p "$HOME/prompts" "$config/system" "$config/tools/probe"
print -r -- '#!/bin/sh' >"$config/tools/probe/run"
chmod +x "$config/tools/probe/run"
print -r -- '{"description":"probe","input_schema":{"type":"object"},"sandbox":false}' \
  >"$config/tools/probe/manifest.json"
print -r -- 'configured' >"$config/system/shared.md"
print -r -- 'home' >"$HOME/prompts/home.md"
sf_test_model probe '{"adapter": "'"$SF_TEST_BACKEND:h"'", "request": {"model": "m"}}'
sf_test_profile unused '{invalid json'

# "@path" selects under the bundled root despite user shadowing; "~/" and
# absolute paths are taken as written. Bare names fall back to bundled.
sf_test_profile default '{"model": ["probe"], "tools": ["probe"], "system": ["shared.md",
  "@system/general.md", "general.md", "~/prompts/home.md", "'"$HOME"'/prompts/home.md"]}'
sf_profile_resolve_args
jq -e --arg base "$config" --rawfile general "$ROOT/share/system/general.md" '
  ($general | sub("\n+$"; "")) as $general |
  .tools == [$base + "/tools/probe"] and
  .system == [{text:(["configured", $general, $general, "home", "home"] | join("\n\n"))}]
' <<<"$REPLY" >/dev/null

# Missing and invalid components fail by kind.
sf_test_profile bad '{"model":["probe"],"tools":["missing"]}'
if sf_profile_resolve_args -p bad; then
  fail 'missing component was accepted'
fi
[[ $SF_PROFILE_ERROR == 'cannot resolve tools reference: missing' ]]
sf_test_profile bad '{"model":["probe"],"hooks":["general.md"]}'
if sf_profile_resolve_args -p bad; then
  fail 'a system file was accepted as a hook'
fi
[[ $SF_PROFILE_ERROR == 'cannot resolve hooks reference: general.md' ]]
(
  SF_SHARE="$tmp/flat-share"
  mkdir -p "$SF_SHARE/hooks"
  print -r -- 'not executable' >"$SF_SHARE/hooks/disabled"
  sf_test_profile bad '{"model":["probe"],"hooks":["@hooks/disabled"]}'
  if sf_profile_resolve_args -p bad; then
    fail 'non-executable hook was accepted'
  fi
  [[ $SF_PROFILE_ERROR == 'invalid hooks reference: @hooks/disabled' ]]
)
