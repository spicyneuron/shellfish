#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/profile.zsh lib/environment.zsh lib/session.zsh

typeset profile tool_name
typeset -r fixture_backend="$ROOT/tests/fixtures/backend"
sf_test_tmp profile
sf_test_config
mkdir -p "$tmp/home"
export HOME="${tmp:A}/home"

sf_test_model fixture '{"adapter": "'"$fixture_backend"'", "request": {"model": "m"}}'
sf_test_model work '{
  "adapter": "@backends/openai",
  "context_window": 128000,
  "request": {"model": "configured", "temperature": 0.2, "reasoning": {"effort": "low"}}
}'
sf_test_model high '{"request": {"reasoning": {"effort": "high"}}}'
sf_test_profile work '{"model": ["work"]}'

# Model files merge left to right, -m merges on top, and --request applies last.
sf_test_profile layered '{"model": ["work", "high"]}'
sf_profile_resolve_args -p layered
jq -e --arg adapter "$ROOT/share/backends/openai" '
  .model == {adapter:$adapter, endpoint:"https://api.openai.com/v1/chat/completions",
    context_window:128000,
    request:{model:"configured",temperature:0.2,reasoning:{effort:"high"}}} and
  del(.model) == {system:[],tools:[],hooks:{},sandbox:true,
    sandbox_read_paths:[],sandbox_write_paths:[]}
' <<<"$REPLY" >/dev/null || fail 'model files did not merge in order'
sf_profile_resolve_args -p work -m high --request '{"temperature":0.7}' --request '{"seed":4}'
jq -e '.model.request == {model:"configured",temperature:0.7,seed:4,reasoning:{effort:"high"}}' \
  <<<"$REPLY" >/dev/null || fail 'model overrides applied in the wrong order'
sf_profile_resolve_args -p work -m fixture
jq -e '.model.adapter | endswith("/tests/fixtures/backend")' <<<"$REPLY" >/dev/null ||
  fail 'a later model file did not replace the adapter'

# A model file endpoint overrides the adapter manifest; null disables discovery.
sf_test_model local '{"endpoint": "http://127.0.0.1:8080/v1/chat/completions", "context_window": null}'
sf_profile_resolve_args -p work -m local
jq -e '.model.endpoint == "http://127.0.0.1:8080/v1/chat/completions" and
  .model.context_window == null' <<<"$REPLY" >/dev/null || fail 'model endpoint was not applied'

# Nested names select by relative path.
mkdir -p "$SF_TEST_CONFIG/system"
print -r -- 'nested' >"$SF_TEST_CONFIG/system/prompt.md"
print -r -- '#!/bin/sh' | sf_test_hook "$SF_TEST_CONFIG/hooks/stop" '{"on":"stop"}'
sf_test_model openai/sol '{"adapter": "openai", "request": {"model": "sol"}}'
sf_test_profile openai/sol '{"model": ["openai/sol"], "system": ["prompt.md"], "hooks": ["stop"]}'
sf_profile_resolve_args -p openai/sol
jq -e --arg root "${SF_TEST_CONFIG:A}" '
  .model.request.model == "sol" and .tools == [] and
  .system == [$root + "/system/prompt.md"] and
  .hooks == {stop: [$root + "/hooks/stop"]}' <<<"$REPLY" >/dev/null
for name in openai//sol openai/../sol /openai/sol openai/sol/; do
  if sf_profile_resolve_args -p "$name"; then
    fail "invalid profile name was accepted: $name"
  fi
  if sf_profile_resolve_args -p work -m "$name"; then
    fail "invalid model name was accepted: $name"
  fi
done

# One profile per session.
if sf_profile_resolve_args -p work -p work; then
  fail 'a repeated --profile was accepted'
fi
[[ $SF_PROFILE_ERROR == '--profile may only be specified once' ]]

# Hooks group by their declared lifecycle, keeping listed order.
typeset hooks="$SF_TEST_CONFIG/hooks"
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/first" '{"on":"stop"}'
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/gate" '{"on":"pre_tool_use"}'
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/second" '{"on":"stop"}'
sf_test_profile hooked '{"model": ["fixture"], "hooks": ["second", "gate", "first"]}'
sf_profile_resolve_args -p hooked
jq -e --arg hooks "${hooks:A}" '
  .hooks == {pre_tool_use: [$hooks + "/gate"], stop: [$hooks + "/second", $hooks + "/first"]}
' <<<"$REPLY" >/dev/null || fail 'hooks did not group by lifecycle in listed order'

# A referenced hook must be runnable and name a lifecycle.
mkdir -p "$hooks/dir"
sf_test_profile hooked '{"model": ["fixture"], "hooks": ["dir"]}'
if sf_profile_resolve_args -p hooked; then
  fail 'incomplete hook directory was accepted'
fi
[[ $SF_PROFILE_ERROR == 'invalid hooks reference: dir' ]]
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/unbound"
sf_test_profile hooked '{"model": ["fixture"], "hooks": ["unbound"]}'
if sf_profile_resolve_args -p hooked; then
  fail 'a hook without a lifecycle was accepted'
fi
[[ $SF_PROFILE_ERROR == *'hook manifest must be valid and declare "on"'* ]]
rm "$hooks/unbound/manifest.json"
if sf_profile_resolve_args -p hooked; then
  fail 'a hook without a manifest was accepted'
fi
[[ $SF_PROFILE_ERROR == 'hook manifest must declare "on": unbound' ]]

# The bundled default profile layers your default model over the bundled one
# and resolves its components under share/.
sf_test_model default '{"adapter": "'"$fixture_backend"'", "request": {"model": "mine"}}'
sf_profile_resolve_args
profile=$REPLY
jq -e --arg share "$ROOT/share/" '
  .model.request == {max_tokens:16384,reasoning:{effort:"medium"},model:"mine"} and
  ([.hooks[][], .tools[], .system[]] | length > 0 and all(.[]; startswith($share)))
' <<<"$profile" >/dev/null || fail 'bundled default profile did not resolve'
sf_profile_resolve_args -p coding
jq -e '(.hooks.permission_request | map(split("/")[-2:] | join("/"))) == ["hooks/review"]' \
  <<<"$REPLY" >/dev/null || fail 'bundled coding profile lost review'

# Tool manifests are read live from the resolved folders.
sf_profile_tools "$profile"
jq -e '
  length > 0 and all(.[]; .name as $name |
    (.command | endswith("/" + $name + "/run")) and .manifest.description != null)
' <<<"$REPLY" >/dev/null

# The bundled model names no model ID.
rm "$SF_TEST_CONFIG/models/default.jsonc"
if sf_profile_resolve_args; then
  fail 'the bundled model resolved without a model ID'
fi
[[ $SF_PROFILE_ERROR == *'a model is required: set request.model'* ]]
sf_profile_resolve_args --request '{"model":"one-off"}'
jq -e '.model.request.model == "one-off" and (.model.adapter | endswith("/backends/openrouter"))' \
  <<<"$REPLY" >/dev/null || fail 'a request override did not complete the bundled model'

# A profile selects; values belong to model files, the environment, or tui.jsonc.
for field in backend request env extend sandbox max_capture_bytes theme_light; do
  sf_test_profile bad "{\"model\": [\"fixture\"], \"$field\": {}}"
  if sf_profile_resolve_args -p bad; then
    fail "profile accepted $field"
  fi
  [[ $SF_PROFILE_ERROR == "invalid configuration: profile bad \$[\"$field\"]: unknown field" ]]
done
for value in '"fixture"' '[1]' '["../fixture"]'; do
  sf_test_profile bad "{\"model\": $value}"
  if sf_profile_resolve_args -p bad; then
    fail "profile accepted model $value"
  fi
done
sf_test_model bad '{"tools": []}'
if sf_profile_resolve_args -p work -m bad; then
  fail 'model file accepted a profile field'
fi
[[ $SF_PROFILE_ERROR == 'invalid configuration: model bad $["tools"]: unknown field' ]]
for value in '{"endpoint":"ftp://example.invalid"}' '{"context_window":0}' '{"request":[]}'; do
  sf_test_model bad "$value"
  if sf_profile_resolve_args -p work -m bad; then
    fail "model file accepted $value"
  fi
done
sf_test_model adapterless '{"request": {"model": "m"}}'
sf_test_profile adapterless '{"model": ["adapterless"]}'
if sf_profile_resolve_args -p adapterless; then
  fail 'a model without an adapter was accepted'
fi
[[ $SF_PROFILE_ERROR == *'a model adapter is required'* ]]
sf_test_profile modelless '{}'
if sf_profile_resolve_args -p modelless; then
  fail 'a profile without a model was accepted'
fi
[[ $SF_PROFILE_ERROR == 'profile selects no model: modelless' ]]
sf_profile_resolve_args -p modelless -m fixture || fail 'a CLI model did not complete a profile'

# A configured file shadows the bundled one, and "@NAME" selects the bundled one.
sf_test_profile coding '{"model": ["fixture"]}'
sf_profile_resolve_args -p coding
jq -e '.hooks == {}' <<<"$REPLY" >/dev/null || fail 'configured profile did not shadow bundled'
sf_test_model default '{"adapter": "'"$fixture_backend"'", "request": {"model": "mine"}}'
sf_profile_resolve_args -p @coding
jq -e '.hooks.permission_request | length == 1' <<<"$REPLY" >/dev/null ||
  fail '@coding did not select the bundled profile'
sf_profile_resolve_args -p work -m @default
jq -e '.model.adapter | endswith("/share/backends/openrouter")' <<<"$REPLY" >/dev/null ||
  fail '@default did not select the bundled model'

# Unknown names fail.
if sf_profile_resolve_args -p absent; then
  fail 'unknown profile was accepted'
fi
[[ $SF_PROFILE_ERROR == 'unknown profile: absent' ]]
if sf_profile_resolve_args -p work -m absent; then
  fail 'unknown model was accepted'
fi
[[ $SF_PROFILE_ERROR == 'unknown model: absent' ]]

# Duplicate tools fail.
sf_test_profile duplicate '{"model": ["fixture"], "tools": ["@tools/read_file", "@tools/read_file"]}'
if sf_profile_resolve_args -p duplicate; then
  fail 'duplicate tool references were accepted'
fi
[[ $SF_PROFILE_ERROR == *'profile tools must be unique: @tools/read_file, @tools/read_file'* ]]

# Malformed files identify their source.
sf_test_profile malformed '{"model":}'
if sf_profile_resolve_args -p malformed; then
  fail 'malformed profile was accepted'
fi
[[ $SF_PROFILE_ERROR == *'invalid profile: '*'malformed.jsonc:'*'parse error:'* ]]
sf_test_model malformed '{"request":}'
if sf_profile_resolve_args -p work -m malformed; then
  fail 'malformed model was accepted'
fi
[[ $SF_PROFILE_ERROR == *'invalid model: '*'malformed.jsonc:'*'parse error:'* ]]

# A backend without a manifest needs an endpoint from a model file.
mkdir -p "$SF_TEST_CONFIG/backends/bare"
print -r -- '#!/bin/sh' >"$SF_TEST_CONFIG/backends/bare/run"
chmod +x "$SF_TEST_CONFIG/backends/bare/run"
sf_test_model bare '{"adapter": "bare", "request": {"model": "m"}}'
sf_test_profile bare '{"model": ["bare"]}'
sf_profile_resolve_args -p bare && fail 'backend without an endpoint was accepted'
sf_test_model bare '{"adapter": "bare", "endpoint": "https://example.invalid", "request": {"model": "m"}}'
sf_profile_resolve_args -p bare || fail 'backend without a manifest was rejected'
sf_test_model bare "{\"adapter\": \"$tmp/not-a-backend\", \"request\": {\"model\": \"m\"}}"
if sf_profile_resolve_args -p bare; then
  fail 'invalid backend path was accepted'
fi

# Sandbox settings come from the environment and flags.
mkdir -p "$tmp/flag"
SHELLFISH_SANDBOX=0 SHELLFISH_SANDBOX_READ="~/my reference:/opt/ref" \
  SHELLFISH_SANDBOX_WRITE="~/output" sf_profile_resolve_args -p work --sandbox-write "$tmp/flag"
jq -e --arg home "${tmp:A}/home" --arg flag "${tmp:A}/flag" '
  .sandbox == false and
  .sandbox_read_paths == [$home + "/my reference", "/opt/ref"] and
  .sandbox_write_paths == [$home + "/output", $flag]
' <<<"$REPLY" >/dev/null || fail 'sandbox settings were not applied'
print -r -- 'SHELLFISH_SANDBOX_READ=/from/env-file' >"$SF_TEST_CONFIG/.env"
sf_profile_resolve_args -p work
jq -e '.sandbox == true and .sandbox_read_paths == ["/from/env-file"]' <<<"$REPLY" >/dev/null ||
  fail '.env sandbox settings were not applied'
rm "$SF_TEST_CONFIG/.env"
if SHELLFISH_SANDBOX=yes sf_profile_resolve_args -p work; then
  fail 'an invalid SHELLFISH_SANDBOX was accepted'
fi
[[ $SF_PROFILE_ERROR == 'SHELLFISH_SANDBOX must be 0 or 1' ]]
if SHELLFISH_SANDBOX_READ=relative sf_profile_resolve_args -p work; then
  fail 'a relative sandbox path was accepted'
fi
(
  unset HOME
  if SHELLFISH_SANDBOX_READ="~/x" sf_profile_resolve_args -p work; then
    fail 'home-relative sandbox path resolved without HOME'
  fi
  [[ $SF_PROFILE_ERROR == *'cannot expand ~ without HOME'* ]]
)

# A missing Shellfish directory uses bundled files.
(
  export SHELLFISH_DIR="$tmp/empty-config"
  sf_profile_resolve_args --request '{"model":"test-model"}'
  jq -e '.model.request.model == "test-model"' <<<"$REPLY" >/dev/null
)

# Manifests reject unknown fields, malformed templates, and bad preview hints.
sf_jq -en '
  include "lib/profile";
  {description:"test",input_schema:{type:"object"},sandbox:false} as $manifest |
  ($manifest | tool_manifest) and ($manifest + {unknown:""} | tool_manifest | not) and
  (["${data.bad-key}","${unclosed","${name}\u0000"] | all(.[]; component_template([]) | not)) and
  (["full",0,12] | all(.[]; component_preview_hint)) and
  ([null,-1,1.5,"3"] | all(.[]; component_preview_hint | not))
' >/dev/null || fail 'manifest validation accepted an invalid value'
sf_jq -en '
  include "lib/profile";
  ({user_text:"${input.custom}"} | component_manifest([]; ["input.custom"])) and
  ({input_schema:{properties:{custom:{}}},user_text:"${input.custom}"} |
    component_manifest(["input_schema"]; []) | not)
' >/dev/null || fail 'shared manifest validation inferred caller template fields'
sf_jq -en '
  include "lib/profile";
  ({match:{pattern:"^/help\\z"}} | hook_manifest) and
  ({on:"stop"} | hook_manifest) and ({on:"session_end"} | hook_manifest | not) and
  ([{match:{pattern:"["}},{match:{pattern:1}},{match:{}},
    {match:{pattern:"x",other:true}}] | all(.[]; hook_manifest | not)) and
  ({match:{pattern:"x"},description:"tool",input_schema:{type:"object"},sandbox:false} |
    tool_manifest | not)
' >/dev/null || fail 'hook match validation failed'
typeset item hook_name example
for item in 'help:/help' 'verbose:/v' 'new:/new' 'resume:/resume' \
    'server:/server' 'copy:/copy 2' 'sandbox:/sandbox read .' \
    'user_shell:!echo hi' 'fork:/fork 2' 'skills:$sample'; do
  hook_name=${item%%:*}
  example=${item#*:}
  sf_jq -en --arg prompt "$example" --slurpfile manifest \
      "$ROOT/share/hooks/$hook_name/manifest.json" '
    include "lib/profile";
    $manifest[0] as $hook |
    ($hook | hook_manifest) and $hook.on == "user_prompt_submit" and
    ($prompt | test($hook.match.pattern)) and
    ("ordinary prompt" | test($hook.match.pattern) | not)
  ' >/dev/null || fail "bundled hook match failed: $hook_name"
done
sf_jq -en --slurpfile manifest "$ROOT/share/hooks/skills/manifest.json" '
  $manifest[0].match.pattern as $pattern |
  (["$", "$-", "$Name", "abc$name", "$$name"] | all(.[]; test($pattern) | not)) and
  (["$name", "$0", "use $name"] | all(.[]; test($pattern)))
' >/dev/null || fail 'skills match accepted a non-name dollar sign'
sf_jq -en --slurpfile manifest "$ROOT/share/hooks/user_shell/manifest.json" '
  "!" | test($manifest[0].match.pattern)
' >/dev/null || fail 'bare shell command lost its usage hook'

# Tool references preserve configured order.
typeset tools="$SF_TEST_CONFIG/tools"
for tool_name in alpha beta gamma delta epsilon; do
  mkdir -p "$tools/$tool_name"
  print -r -- '#!/bin/sh' >"$tools/$tool_name/run"
  chmod +x "$tools/$tool_name/run"
  jq -n --arg description "$tool_name tool" \
    '{description:$description,input_schema:{type:"object"},sandbox:false}' \
    >"$tools/$tool_name/manifest.json"
done
mv "$tools/beta/manifest.json" "$tools/beta/manifest.jsonc"
sf_test_profile tooled '{"model": ["fixture"], "tools": ["beta", "alpha", "gamma", "delta", "epsilon"]}'
sf_profile_resolve_args -p tooled
jq -e --arg base "${tools:A}" '
  .tools == [($base + "/beta"), ($base + "/alpha"), ($base + "/gamma"), ($base + "/delta"),
    ($base + "/epsilon")]
' <<<"$REPLY" >/dev/null
sf_profile_tools "$REPLY"
jq -e --arg base "${tools:A}" '
  map(.name) == ["beta", "alpha", "gamma", "delta", "epsilon"] and
  .[0] == {name:"beta",command:($base + "/beta/run"),
    manifest:{description:"beta tool",input_schema:{type:"object"},sandbox:false}}
' <<<"$REPLY" >/dev/null
cp "$tools/beta/manifest.jsonc" "$tools/beta/manifest.json"
if sf_profile_resolve_args -p tooled; then
  fail 'component with ambiguous manifests was accepted'
fi
[[ $SF_PROFILE_ERROR == "multiple component manifests: ${tools:A}/beta" ]]
rm "$tools/beta/manifest.json"

mv "$tools/gamma/manifest.json" "$tmp/gamma.json"
sf_profile_resolve_args -p tooled && fail 'tool without a manifest was accepted'
mv "$tmp/gamma.json" "$tools/gamma/manifest.json"

# Environment values load from the config directory's .env: selected names, or
# every entry.
typeset environment_file="$SF_TEST_CONFIG/.env"
cat >"$environment_file" <<'ENV'
export OPENAI_API_KEY = "from-file"
ANTHROPIC_API_KEY=other-file
ENV
sf_environment_load OPENAI_API_KEY
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=from-file' && $REPLY == ${SF_TEST_CONFIG:A} ]]
sf_environment_load
[[ ${(oj: :)SF_ENVIRONMENT_VALUES} == 'ANTHROPIC_API_KEY=other-file OPENAI_API_KEY=from-file' ]]
sf_environment_settings 'OPENAI_API_KEY MISSING'
[[ ${(kj: :)SF_ENVIRONMENT_SETTINGS} == OPENAI_API_KEY &&
   $SF_ENVIRONMENT_SETTINGS[OPENAI_API_KEY] == from-file ]]

# Exported values win: selected names carry them, and a full load leaves them
# to inheritance.
export OPENAI_API_KEY=''
sf_environment_load OPENAI_API_KEY
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=' ]]
sf_environment_load
[[ ${(oj: :)SF_ENVIRONMENT_VALUES} == 'ANTHROPIC_API_KEY=other-file' ]]
unset OPENAI_API_KEY

print -r -- 'invalid line' >>"$environment_file"
if sf_environment_load OPENAI_API_KEY; then
  fail 'invalid env file tail was accepted'
fi
