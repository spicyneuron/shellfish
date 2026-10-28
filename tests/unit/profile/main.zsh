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

# Model files merge left to right, and -m items merge on top in order.
sf_test_profile layered '{"model": ["work", "high"]}'
sf_profile_resolve_args -p layered
jq -e --arg adapter "$ROOT/share/backends/openai" '
  .model == {adapter:$adapter, endpoint:"https://api.openai.com/v1/chat/completions",
    context_window:128000,
    request:{model:"configured",temperature:0.2,reasoning:{effort:"high"}}} and
  del(.model) == {system:[],tools:[],hooks:[],sandbox:{enabled:true,read:[],write:[]}}
' <<<"$REPLY" >/dev/null || fail 'model files did not merge in order'
sf_profile_resolve_args -p work -m high -m '{"request":{"temperature":0.7}}' \
  -m '{"request":{"seed":4}}'
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
  .system == [{text:"nested"}] and
  .hooks == [$root + "/hooks/stop"]' <<<"$REPLY" >/dev/null

# A path is taken as written, and "@" is the bundled root.
sf_profile_resolve_args -p "$SF_TEST_CONFIG/profiles/openai/sol.jsonc" \
  -m '{"adapter": "@backends/openrouter"}'
jq -e '.model.request.model == "sol" and (.model.adapter | endswith("/share/backends/openrouter"))' \
  <<<"$REPLY" >/dev/null || fail 'path references did not select their files'

# "./" and "../" are relative to the file that wrote them, or to the working
# directory for a flag.
typeset kit="$tmp/kit"
mkdir -p "$kit/profiles" "$kit/models" "$kit/sandbox" "$kit/system"
print -r -- 'kit' >"$kit/system/kit.md"
cp -R "$ROOT/tests/fixtures/backend" "$tmp/tests-backend"
print -r -- '{"adapter": "./../../tests-backend", "request": {"model": "kit"}}' \
  >"$kit/models/kit.jsonc"
print -r -- '{"read": ["./data", "../system"]}' >"$kit/sandbox/kit.jsonc"
print -r -- '{"model": ["../models/kit.jsonc"], "sandbox": ["../sandbox/kit.jsonc"],
  "system": ["../system/kit.md"]}' >"$kit/profiles/kit.jsonc"
sf_profile_resolve_args -p "$kit/profiles/kit.jsonc"
jq -e --arg kit "${kit:A}" --arg backend "${tmp:A}/tests-backend" '
  .model.adapter == $backend and .system == [{text:"kit"}] and
  .sandbox.read == [$kit + "/sandbox/data", $kit + "/system"]
' <<<"$REPLY" >/dev/null || fail 'config-relative references did not resolve from their files'
(
  cd "$kit"
  sf_profile_resolve_args -p ./profiles/kit.jsonc -m ./models/kit.jsonc
  jq -e '.model.request.model == "kit"' <<<"$REPLY" >/dev/null
) || fail 'flag-relative references did not resolve from the working directory'

# Model, sandbox, and system lists take inline values, a lone model or sandbox
# item needs no list, system files freeze into one text, and a frozen profile
# resolves to itself.
sf_test_profile inline '{"model": {"adapter": "'"$fixture_backend"'", "request": {"model": "inline"}},
  "sandbox": {"read": ["./data"]}, "system": [{"text": "hello"}, "prompt.md"]}'
sf_profile_resolve_args -p inline
profile=$REPLY
jq -e --arg root "${SF_TEST_CONFIG:A}" '
  .model.request.model == "inline" and .sandbox.read == [$root + "/profiles/data"] and
  .system == [{text:"hello\n\nnested"}]
' <<<"$profile" >/dev/null || fail 'inline profile items did not resolve'
print -r -- "$profile" >"$tmp/frozen.jsonc"
sf_profile_resolve_args -p "$tmp/frozen.jsonc"
[[ $REPLY == "$profile" ]] || fail 'a frozen profile did not resolve to itself'

for name in '' $'open\nai'; do
  if sf_profile_resolve_args -p "$name"; then
    fail "invalid profile reference was accepted: $name"
  fi
  if sf_profile_resolve_args -p work -m "$name"; then
    fail "invalid model reference was accepted: $name"
  fi
done

# One profile per session.
if sf_profile_resolve_args -p work -p work; then
  fail 'a repeated --profile was accepted'
fi
[[ $SF_PROFILE_ERROR == '--profile may only be specified once' ]]

# Hooks keep their listed order; a run groups them by declared lifecycle.
typeset hooks="$SF_TEST_CONFIG/hooks"
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/first" '{"on":"stop"}'
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/gate" '{"on":"pre_tool_use"}'
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/second" '{"on":"stop"}'
sf_test_profile hooked '{"model": ["fixture"], "hooks": ["second", "gate", "first"]}'
sf_profile_resolve_args -p hooked
jq -e --arg hooks "${hooks:A}" '
  .hooks == [$hooks + "/second", $hooks + "/gate", $hooks + "/first"]
' <<<"$REPLY" >/dev/null || fail 'hooks did not keep listed order'

# A referenced hook must be runnable, and its manifest, read when a run loads
# components, must name a lifecycle.
mkdir -p "$hooks/dir"
sf_test_profile hooked '{"model": ["fixture"], "hooks": ["dir"]}'
if sf_profile_resolve_args -p hooked; then
  fail 'incomplete hook directory was accepted'
fi
[[ $SF_PROFILE_ERROR == 'invalid hooks reference: dir' ]]
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/unbound"
sf_test_profile hooked '{"model": ["fixture"], "hooks": ["unbound"]}'
sf_profile_resolve_args -p hooked
profile=$REPLY
if sf_profile_components hooks "$profile"; then
  fail 'a hook without a lifecycle was accepted'
fi
[[ $SF_PROFILE_ERROR == *'hook manifest must be valid and declare "on"'* ]]
rm "$hooks/unbound/manifest.json"
if sf_profile_components hooks "$profile"; then
  fail 'a hook without a manifest was accepted'
fi
[[ $SF_PROFILE_ERROR == *'hook manifest must be valid and declare "on"'* ]]

# Template profiles resolve their components under share/ once the template
# model names a model. Only plus opts into child agents and review.
cp "$ROOT/share/template/models/default.jsonc" "$SF_TEST_CONFIG/models/default.jsonc"
sf_test_sandbox default "$(<"$ROOT/share/template/sandbox/default.jsonc")"
for name in default basic readonly plus; do
  sf_profile_resolve_args -p "@template/profiles/$name.jsonc" -m '{"request":{"model":"mine"}}'
  profile=$REPLY
  jq -e --arg share "$ROOT/share/" --arg name "$name" '
    .model.request == {max_tokens:16384,reasoning:{effort:"medium"},model:"mine"} and
    ([.hooks[], .tools[]] | length > 0 and all(.[]; startswith($share))) and
    (.system[0].text | length > 0) and
    ((.tools | any(endswith("/agent"))) == ($name == "plus")) and
    ((.hooks | any(endswith("/review"))) == ($name == "plus"))
  ' <<<"$profile" >/dev/null || fail "template profile did not resolve: $name"
done

# Tool manifests are read live from the resolved folders.
sf_profile_components tools "$profile"
jq -e '
  length > 0 and all(.[]; .name as $name |
    (.command | endswith("/" + $name + "/run")) and .manifest.description != null)
' <<<"$REPLY" >/dev/null

# The template model names a placeholder until edited.
sf_profile_resolve_args -p "@template/profiles/default.jsonc"
jq -e '.model.request.model == "MODEL"' <<<"$REPLY" >/dev/null ||
  fail 'the template model lost its placeholder'
rm "$SF_TEST_CONFIG/models/default.jsonc" "$SF_TEST_CONFIG/sandbox/default.jsonc"

# A profile selects; values belong to model files, the environment, or tui.jsonc.
for field in backend request env extend max_capture_bytes theme_light; do
  sf_test_profile bad "{\"model\": [\"fixture\"], \"$field\": {}}"
  if sf_profile_resolve_args -p bad; then
    fail "profile accepted $field"
  fi
  [[ $SF_PROFILE_ERROR == "invalid configuration: profile bad \$[\"$field\"]: unknown field" ]]
done
for value in '1' '[1]' '[""]'; do
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
[[ $SF_PROFILE_ERROR == 'invalid configuration: profile selects no model: modelless' ]]
sf_profile_resolve_args -p modelless -m fixture || fail 'a CLI model did not complete a profile'

# A configured component shadows the bundled one, and "@" still reaches it.
mkdir -p "$SF_TEST_CONFIG/system"
print -r -- 'mine' >"$SF_TEST_CONFIG/system/general.md"
sf_test_profile shadow '{"model": ["fixture"], "system": ["general.md", "@system/general.md"]}'
sf_profile_resolve_args -p shadow
jq -e --rawfile general "$ROOT/share/system/general.md" '
  .system == [{text:("mine\n\n" + ($general | sub("\n+$"; "")))}]
' <<<"$REPLY" >/dev/null || fail 'configured component did not shadow bundled'
rm "$SF_TEST_CONFIG/system/general.md"

# Unknown names fail.
if sf_profile_resolve_args -p absent; then
  fail 'unknown profile was accepted'
fi
[[ $SF_PROFILE_ERROR == 'unknown profile: absent' ]]
if sf_profile_resolve_args -p work -m absent; then
  fail 'unknown model was accepted'
fi
[[ $SF_PROFILE_ERROR == 'unknown model: absent' ]]

# Options append to lists, a repeated reference collapses to the first, and
# references reaching the same tool fail.
sf_test_profile duplicate '{"model": ["fixture"], "tools": ["@tools/read_file", "@tools/shell"]}'
sf_profile_resolve_args -p duplicate -t @tools/read_file -t edit_file
jq -e '.tools | map(split("/") | last) == ["read_file", "shell", "edit_file"]' \
  <<<"$REPLY" >/dev/null || fail 'tool options did not append without repeats'
if sf_profile_resolve_args -p duplicate -t read_file; then
  fail 'two references to one tool were accepted'
fi
for option in '-m {' '--sandbox [1]' '-t {"a":1}' '--system {"text":1}'; do
  if sf_profile_resolve_args -p duplicate ${=option}; then
    fail "invalid option value was accepted: $option"
  fi
done

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

# Sandbox files merge left to right: grants accumulate, "enabled" replaces, and
# flags add grants last. Grants need not exist.
mkdir -p "$tmp/flag"
sf_test_sandbox base '{"read": ["~/my reference", "/opt/ref"], "write": ["~/output"]}'
sf_test_sandbox off '{"enabled": false, "read": ["@system"]}'
sf_test_sandbox on '{"enabled": true}'
sf_test_profile boxed '{"model": ["work"], "sandbox": ["base", "off"]}'
(cd "$tmp" && sf_profile_resolve_args -p boxed --sandbox '{"write":["./flag"]}' &&
  print -r -- "$REPLY") | read -r REPLY
jq -e --arg home "${tmp:A}/home" --arg flag "${tmp:A}/flag" --arg share "$ROOT/share" '
  .sandbox == {enabled:false, read:[$home + "/my reference", "/opt/ref", $share + "/system"],
    write:[$home + "/output", $flag]}
' <<<"$REPLY" >/dev/null || fail 'sandbox files did not merge in order'
sf_test_profile boxed '{"model": ["work"], "sandbox": ["off", "on"]}'
sf_profile_resolve_args -p boxed
jq -e '.sandbox.enabled' <<<"$REPLY" >/dev/null || fail 'a later sandbox file did not re-enable'

# Invalid sandbox files name the file and entry.
sf_test_sandbox bad '{"read": ["/ok", "relative"]}'
sf_test_profile boxed '{"model": ["work"], "sandbox": ["bad"]}'
if sf_profile_resolve_args -p boxed; then
  fail 'a bare sandbox name was accepted'
fi
[[ $SF_PROFILE_ERROR == 'invalid configuration: sandbox bad $["read"][1]: must be a /, ~/, ./, ../, or @ path' ]]
for value in '{"enabled": "yes"}' '{"write": "/x"}' '{"paths": []}'; do
  sf_test_sandbox bad "$value"
  if sf_profile_resolve_args -p boxed; then
    fail "sandbox file accepted $value"
  fi
done
sf_test_profile boxed '{"model": ["work"], "sandbox": ["absent"]}'
if sf_profile_resolve_args -p boxed; then
  fail 'unknown sandbox file was accepted'
fi
[[ $SF_PROFILE_ERROR == 'unknown sandbox: absent' ]]
sf_test_profile boxed '{"model": ["work"], "sandbox": ["base"]}'
(
  unset HOME
  if sf_profile_resolve_args -p boxed; then
    fail 'home-relative sandbox path resolved without HOME'
  fi
  [[ $SF_PROFILE_ERROR == *'cannot expand ~ without HOME'* ]]
)

# init writes the template, keeping existing files, and its profiles resolve
# by name once a model is named.
(
  export SHELLFISH_DIR="$tmp/initialized"
  mkdir -p "$SHELLFISH_DIR"
  print -r -- 'mine' >"$SHELLFISH_DIR/.env"
  "$ROOT/bin/shellfish" init >"$tmp/init.out"
  grep -qx "kept  ${SHELLFISH_DIR:A}/.env" "$tmp/init.out"
  [[ $(<"$SHELLFISH_DIR/.env") == mine ]]
  for name in default basic readonly plus; do
    sf_profile_resolve_args -p $name -m '{"request":{"model":"mine"}}' >/dev/null
  done
  sf_profile_resolve_args
  jq -e '.model.request.model == "MODEL"' <<<"$REPLY" >/dev/null
) || fail 'init did not write a resolvable configuration'

# Without a profile, options select everything, and no model is an error.
(
  export SHELLFISH_DIR="$tmp/empty-config"
  if sf_profile_resolve_args; then
    fail 'an empty selection was accepted'
  fi
  [[ $SF_PROFILE_ERROR == *'no model selected: run shellfish init, or pass -m'* ]]
  sf_profile_resolve_args -m '{"adapter":"openrouter","request":{"model":"test-model"}}' -t shell
  jq -e '.model.request.model == "test-model" and (.tools | length) == 1 and .system == []' \
    <<<"$REPLY" >/dev/null
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
sf_profile_components tools "$REPLY"
jq -e --arg base "${tools:A}" '
  map(.name) == ["beta", "alpha", "gamma", "delta", "epsilon"] and
  .[0] == {name:"beta",command:($base + "/beta/run"),
    manifest:{description:"beta tool",input_schema:{type:"object"},sandbox:false}}
' <<<"$REPLY" >/dev/null
cp "$tools/beta/manifest.jsonc" "$tools/beta/manifest.json"
sf_profile_resolve_args -p tooled
profile=$REPLY
if sf_profile_components tools "$profile"; then
  fail 'component with ambiguous manifests was accepted'
fi
[[ $SF_PROFILE_ERROR == "multiple component manifests: ${tools:A}/beta" ]]
rm "$tools/beta/manifest.json"

mv "$tools/gamma/manifest.json" "$tmp/gamma.json"
sf_profile_components tools "$profile" && fail 'tool without a manifest was accepted'
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
