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
sf_test_profile work '{}'

# -m selects the model, and repeated -m items merge left to right.
sf_profile_resolve_args -p work -m work -m high
jq -e --arg adapter "$ROOT/share/backends/openai" '
  .model == {adapter:$adapter, endpoint:"https://api.openai.com/v1/chat/completions",
    context_window:128000,
    request:{model:"configured",temperature:0.2,reasoning:{effort:"high"}}} and
  .profile == {system:[],tools:[],commands:[],hooks:[],sandbox:{enabled:true,read:[],write:[]}} and
  keys == ["model", "profile"]
' <<<"$REPLY" >/dev/null || fail 'model files did not merge in order'
sf_profile_resolve_args -p work -m work -m high -m '{"request":{"temperature":0.7}}' \
  -m '{"request":{"seed":4}}'
jq -e '.model.request == {model:"configured",temperature:0.7,seed:4,reasoning:{effort:"high"}}' \
  <<<"$REPLY" >/dev/null || fail 'model overrides applied in the wrong order'
sf_profile_resolve_args -p work -m fixture
jq -e '.model.request == {model:"m"} and (.model.adapter | endswith("/tests/fixtures/backend")) and
  (.model | has("context_window") | not)' <<<"$REPLY" >/dev/null ||
  fail 'a selected model did not stand alone'

# Without -m, models/default is the model.
sf_test_model default '{"adapter": "@backends/openai", "request": {"model": "fallback"}}'
sf_profile_resolve_args -p work
jq -e '.model.request.model == "fallback"' <<<"$REPLY" >/dev/null ||
  fail 'models/default was not the default model'
sf_profile_resolve_args -p work -m fixture
jq -e '.model.request.model == "m"' <<<"$REPLY" >/dev/null ||
  fail 'models/default merged under a selected model'
rm "$SF_TEST_CONFIG/models/default.jsonc"

# A model file endpoint overrides the adapter manifest; null disables discovery.
sf_test_model local '{"endpoint": "http://127.0.0.1:8080/v1/chat/completions", "context_window": null}'
sf_profile_resolve_args -p work -m work -m local
jq -e '.model.endpoint == "http://127.0.0.1:8080/v1/chat/completions" and
  .model.context_window == null' <<<"$REPLY" >/dev/null || fail 'model endpoint was not applied'

# Nested names select by relative path.
mkdir -p "$SF_TEST_CONFIG/system"
print -r -- 'nested' >"$SF_TEST_CONFIG/system/prompt.md"
print -r -- '#!/bin/sh' | sf_test_hook "$SF_TEST_CONFIG/hooks/stop" '{"on":"stop"}'
sf_test_model openai/sol '{"adapter": "openai", "request": {"model": "sol"}}'
sf_test_profile openai/sol '{"system": ["prompt.md"], "hooks": ["stop"]}'
sf_profile_resolve_args -p openai/sol -m openai/sol
jq -e --arg root "${SF_TEST_CONFIG:A}" '
  .model.request.model == "sol" and .profile.tools == [] and
  .profile.system == [{text:"nested"}] and
  .profile.hooks == [$root + "/hooks/stop"]' <<<"$REPLY" >/dev/null

# A path is taken as written, and "@" is the bundled root.
sf_profile_resolve_args -p "$SF_TEST_CONFIG/profiles/openai/sol.jsonc" \
  -m "$SF_TEST_CONFIG/models/openai/sol.jsonc" -m '{"adapter": "@backends/openrouter"}'
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
print -r -- '{"sandbox": ["../sandbox/kit.jsonc"], "system": ["../system/kit.md"]}' \
  >"$kit/profiles/kit.jsonc"
sf_profile_resolve_args -p "$kit/profiles/kit.jsonc" -m "$kit/models/kit.jsonc"
jq -e --arg kit "${kit:A}" --arg backend "${tmp:A}/tests-backend" '
  .model.adapter == $backend and .profile.system == [{text:"kit"}] and
  .profile.sandbox.read == [$kit + "/sandbox/data", $kit + "/system"]
' <<<"$REPLY" >/dev/null || fail 'config-relative references did not resolve from their files'
(
  cd "$kit"
  sf_profile_resolve_args -p ./profiles/kit.jsonc -m ./models/kit.jsonc
  jq -e '.model.request.model == "kit"' <<<"$REPLY" >/dev/null
) || fail 'flag-relative references did not resolve from the working directory'

# Sandbox and system lists take inline values, a lone sandbox item needs no
# list, system files freeze into one text, and a frozen profile and model
# resolve to themselves.
sf_test_profile inline '{"sandbox": {"read": ["./data"]},
  "system": [{"text": "hello"}, "prompt.md"],
  "config": {"example": {"paths": ["./data", "~/data", "@data"], "values": [null, false, 2]}}}'
sf_profile_resolve_args -p inline -m '{"adapter": "'"$fixture_backend"'", "request": {"model": "inline"},
  "config": {"example": {"paths": ["./data", "~/data", "@data"], "values": [null, false, 2]}}}'
profile=$REPLY
jq -e --arg root "${SF_TEST_CONFIG:A}" '
  .model.request.model == "inline" and .profile.sandbox.read == [$root + "/profiles/data"] and
  .profile.system == [{text:"hello\n\nnested"}] and
  .profile.config == {example:{paths:["./data", "~/data", "@data"], values:[null,false,2]}} and
  .model.config == .profile.config
' <<<"$profile" >/dev/null || fail 'inline profile items did not resolve'
jq '.profile' <<<"$profile" >"$tmp/frozen.jsonc"
jq '.model' <<<"$profile" >"$tmp/frozen-model.jsonc"
sf_profile_resolve_args -p "$tmp/frozen.jsonc" -m "$tmp/frozen-model.jsonc"
[[ $REPLY == "$profile" ]] || fail 'a frozen profile and model did not resolve to themselves'

# Supplied configuration freezes without rereading the source profile or model.
"$ROOT/bin/shellfish" run --session-create --session-out "$tmp/config.jsonl" \
  -p inline -m "$tmp/frozen-model.jsonc" >/dev/null
sf_test_profile inline '{"config":{"example":"changed"}}'
print -r -- '{"config":{"example":"changed"}}' >"$tmp/frozen-model.jsonc"
sf_session_read_config "$tmp/config.jsonl"
jq -e '.profile.config == {example:{paths:["./data", "~/data", "@data"], values:[null,false,2]}} and
  .model.config == .profile.config' <<<"$REPLY" >/dev/null ||
  fail 'session configuration changed with its source files'
for value in null false 1 '"text"' '[]'; do
  sf_test_profile bad "{\"config\":$value}"
  if sf_profile_resolve_args -p bad -m fixture; then
    fail "profile accepted non-object config: $value"
  fi
  [[ $SF_PROFILE_ERROR == 'invalid configuration: profile bad $["config"]: must be an object' ]]
done

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
sf_test_profile hooked '{"hooks": ["second", "gate", "first"]}'
sf_profile_resolve_args -p hooked -m fixture
jq -e --arg hooks "${hooks:A}" '
  .profile.hooks == [$hooks + "/second", $hooks + "/gate", $hooks + "/first"]
' <<<"$REPLY" >/dev/null || fail 'hooks did not keep listed order'

# A referenced hook must be runnable, and its manifest, read when a run loads
# components, must name a lifecycle.
mkdir -p "$hooks/dir"
sf_test_profile hooked '{"hooks": ["dir"]}'
if sf_profile_resolve_args -p hooked -m fixture; then
  fail 'incomplete hook directory was accepted'
fi
[[ $SF_PROFILE_ERROR == 'invalid hooks reference: dir' ]]
print -r -- '#!/bin/sh' | sf_test_hook "$hooks/unbound"
sf_test_profile hooked '{"hooks": ["unbound"]}'
sf_profile_resolve_args -p hooked -m fixture
profile=$(jq -c '.profile' <<<"$REPLY")
if sf_profile_components hooks "$profile"; then
  fail 'a hook without a lifecycle was accepted'
fi
[[ $SF_PROFILE_ERROR == *'hook manifest must be valid and declare "on"'* ]]
rm "$hooks/unbound/manifest.json"
if sf_profile_components hooks "$profile"; then
  fail 'a hook without a manifest was accepted'
fi
[[ $SF_PROFILE_ERROR == *'hook manifest must be valid and declare "on"'* ]]

# Template profiles resolve their components under share/ with the template
# model. Only plus opts into child agents and review.
cp "$ROOT/share/template/models/default.jsonc" "$SF_TEST_CONFIG/models/default.jsonc"
sf_test_sandbox default "$(<"$ROOT/share/template/sandbox/default.jsonc")"
for name in default basic readonly plus; do
  sf_profile_resolve_args -p "@template/profiles/$name.jsonc" -m default \
    -m '{"request":{"model":"mine"}}'
  jq -e --arg share "$ROOT/share/" --arg name "$name" '
    .model.request == {max_tokens:16384,reasoning:{effort:"medium"},model:"mine"} and
    (.profile |
      ([.commands[], .hooks[], .tools[]] | length > 0 and all(.[]; startswith($share))) and
      (.commands | any(endswith("/help"))) and
      (.system[0].text | length > 0) and
      ((.tools | any(endswith("/agent"))) == ($name == "plus")) and
      ((.hooks | any(endswith("/sandbox-approver"))) == ($name == "plus")))
  ' <<<"$REPLY" >/dev/null || fail "template profile did not resolve: $name"
  profile=$(jq -c '.profile' <<<"$REPLY")
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

# Provider and presentation settings stay outside the profile's own fields.
for field in model backend request env extend max_capture_bytes theme_light; do
  sf_test_profile bad "{\"$field\": {}}"
  if sf_profile_resolve_args -p bad -m fixture; then
    fail "profile accepted $field"
  fi
  [[ $SF_PROFILE_ERROR == "invalid configuration: profile bad \$[\"$field\"]: unknown field" ]]
done
for value in '1' '[1]' '[""]'; do
  if sf_profile_resolve_args -p work -m "$value"; then
    fail "model option accepted $value"
  fi
done
sf_test_model bad '{"tools": []}'
if sf_profile_resolve_args -p work -m bad; then
  fail 'model file accepted a profile field'
fi
[[ $SF_PROFILE_ERROR == 'invalid configuration: model bad $["tools"]: unknown field' ]]
for value in '{"endpoint":"ftp://example.invalid"}' '{"context_window":0}' '{"request":[]}' \
    '{"config":null}' '{"config":[]}' '{"config":false}' '{"config":1}' '{"config":"text"}'; do
  sf_test_model bad "$value"
  if sf_profile_resolve_args -p work -m bad; then
    fail "model file accepted $value"
  fi
done
sf_test_model adapterless '{"request": {"model": "m"}}'
if sf_profile_resolve_args -p work -m adapterless; then
  fail 'a model without an adapter was accepted'
fi
[[ $SF_PROFILE_ERROR == *'a model adapter is required'* ]]
if sf_profile_resolve_args -p work; then
  fail 'a missing default model was accepted'
fi
[[ $SF_PROFILE_ERROR == 'no model selected: run shellfish init, or pass -m' ]]

# A configured component shadows the bundled one, and "@" still reaches it.
mkdir -p "$SF_TEST_CONFIG/system"
print -r -- 'mine' >"$SF_TEST_CONFIG/system/general.md"
sf_test_profile shadow '{"system": ["general.md", "@system/general.md"]}'
sf_profile_resolve_args -p shadow -m fixture
jq -e --rawfile general "$ROOT/share/system/general.md" '
  .profile.system == [{text:("mine\n\n" + ($general | sub("\n+$"; "")))}]
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
sf_test_profile duplicate '{"tools": ["@tools/read_file", "@tools/shell"]}'
sf_profile_resolve_args -p duplicate -m fixture -t @tools/read_file -t edit_file
jq -e '.profile.tools | map(split("/") | last) == ["read_file", "shell", "edit_file"]' \
  <<<"$REPLY" >/dev/null || fail 'tool options did not append without repeats'
if sf_profile_resolve_args -p duplicate -m fixture -t read_file; then
  fail 'two references to one tool were accepted'
fi
for option in '-m {' '--sandbox [1]' '-t {"a":1}' '--system {"text":1}'; do
  if sf_profile_resolve_args -p duplicate -m fixture ${=option}; then
    fail "invalid option value was accepted: $option"
  fi
done

# Malformed files identify their source.
sf_test_profile malformed '{"tools":}'
if sf_profile_resolve_args -p malformed -m fixture; then
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
sf_profile_resolve_args -p work -m bare && fail 'backend without an endpoint was accepted'
sf_test_model bare '{"adapter": "bare", "endpoint": "https://example.invalid", "request": {"model": "m"}}'
sf_profile_resolve_args -p work -m bare || fail 'backend without a manifest was rejected'
sf_test_model bare "{\"adapter\": \"$tmp/not-a-backend\", \"request\": {\"model\": \"m\"}}"
if sf_profile_resolve_args -p work -m bare; then
  fail 'invalid backend path was accepted'
fi

# Sandbox files merge left to right: grants accumulate, settings replace, and
# flags add grants last. Grants need not exist.
mkdir -p "$tmp/flag"
sf_test_sandbox base '{"read": ["~/my reference", "/opt/ref"], "write": ["~/output"]}'
sf_test_sandbox off '{"enabled": false, "user_approval_timeout": 30, "read": ["@system"]}'
sf_test_sandbox on '{"enabled": true}'
sf_test_profile boxed '{"sandbox": ["base", "off"]}'
(cd "$tmp" && sf_profile_resolve_args -p boxed -m work --sandbox '{"write":["./flag"]}' &&
  print -r -- "$REPLY") | read -r REPLY
jq -e --arg home "${tmp:A}/home" --arg flag "${tmp:A}/flag" --arg share "$ROOT/share" '
  .profile.sandbox == {enabled:false, user_approval_timeout:30, read:[$home + "/my reference", "/opt/ref", $share + "/system"],
    write:[$home + "/output", $flag]}
' <<<"$REPLY" >/dev/null || fail 'sandbox files did not merge in order'
sf_test_profile boxed '{"sandbox": ["off", "on"]}'
sf_profile_resolve_args -p boxed -m work
jq -e '.profile.sandbox.enabled' <<<"$REPLY" >/dev/null || fail 'a later sandbox file did not re-enable'

# Invalid sandbox files name the file and entry.
sf_test_sandbox bad '{"read": ["/ok", "relative"]}'
sf_test_profile boxed '{"sandbox": ["bad"]}'
if sf_profile_resolve_args -p boxed -m work; then
  fail 'a bare sandbox name was accepted'
fi
[[ $SF_PROFILE_ERROR == 'invalid configuration: sandbox bad $["read"][1]: must be a /, ~/, ./, ../, or @ path' ]]
for value in '{"enabled": "yes"}' '{"write": "/x"}' '{"paths": []}' \
    '{"user_approval_timeout": 0}' '{"user_approval_timeout": 1.5}'; do
  sf_test_sandbox bad "$value"
  if sf_profile_resolve_args -p boxed -m work; then
    fail "sandbox file accepted $value"
  fi
done
sf_test_profile boxed '{"sandbox": ["absent"]}'
if sf_profile_resolve_args -p boxed -m work; then
  fail 'unknown sandbox file was accepted'
fi
[[ $SF_PROFILE_ERROR == 'unknown sandbox: absent' ]]
sf_test_profile boxed '{"sandbox": ["base"]}'
(
  unset HOME
  if sf_profile_resolve_args -p boxed -m work; then
    fail 'home-relative sandbox path resolved without HOME'
  fi
  [[ $SF_PROFILE_ERROR == *'cannot expand ~ without HOME'* ]]
)

# init writes the template, keeping existing files, and its profiles resolve
# by name with its default model.
(
  export SHELLFISH_DIR="$tmp/initialized"
  mkdir -p "$SHELLFISH_DIR"
  print -r -- 'mine' >"$SHELLFISH_DIR/.env"
  "$ROOT/bin/shellfish" init >"$tmp/init.out"
  grep -qx "kept  ${SHELLFISH_DIR:A}/.env" "$tmp/init.out"
  [[ $(<"$SHELLFISH_DIR/.env") == mine ]]
  for name in default basic readonly plus; do
    sf_profile_resolve_args -p $name -m default -m '{"request":{"model":"mine"}}' >/dev/null
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
  jq -e '.model.request.model == "test-model" and (.profile.tools | length) == 1 and
    .profile.system == []' \
    <<<"$REPLY" >/dev/null
)

# Manifests reject unknown fields, malformed templates, and bad preview hints.
sf_jq -en '
  include "lib/profile";
  {description:"test",input_schema:{type:"object"},sandbox:false} as $manifest |
  ($manifest | tool_manifest) and ($manifest + {unknown:""} | tool_manifest | not) and
  (["${name}","${output.exit_code}","${input}\u0000"] | all(.[]; component_template([]) | not)) and
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
  render_template("${input.a.b}|${input.a}|${output.stdout}";
    {input:{"a.b":"dotted",a:"text"},output:{stdout:"out"}}) == "dotted|text|out"
' >/dev/null || fail 'template placeholders did not resolve literal keys'
sf_jq -en '
  include "lib/profile";
  ({match:{pattern:"^/help\\z"}} | hook_manifest) and
  ({on:"stop"} | hook_manifest) and ({on:"session_end"} | hook_manifest | not) and
  ([{match:{pattern:"["}},{match:{pattern:1}},{match:{}},
    {match:{pattern:"x",other:true}}] | all(.[]; hook_manifest | not)) and
  ({match:{pattern:"x"},description:"tool",input_schema:{type:"object"},sandbox:false} |
    tool_manifest | not)
' >/dev/null || fail 'hook match validation failed'
sf_jq -en '
  include "lib/profile";
  ({description:"Copy",arguments:"[N]",aliases:["c"],user_text:"${output.stderr}"} |
    command_manifest) and
  ([{}, {description:""}, {description:"x",arguments:""}, {description:"x",aliases:["c","c"]},
    {description:"x",aliases:["/c"]}, {description:"x",on:"stop"}] |
    all(.[]; command_manifest | not))
' >/dev/null || fail 'command manifest validation failed'
typeset hook_name
for hook_name in "$ROOT"/share/commands/*(/); do
  sf_jq -en --slurpfile manifest "$hook_name/manifest.json" '
    include "lib/profile";
    $manifest[0] | command_manifest
  ' >/dev/null || fail "bundled command manifest is invalid: ${hook_name:t}"
done
sf_jq -en --slurpfile manifest "$ROOT/share/hooks/skills/mention/manifest.json" '
  include "lib/profile";
  $manifest[0].match.pattern as $pattern |
  ($manifest[0] | hook_manifest and .on == "user_prompt_submit") and
  (["$", "$-", "$Name", "abc$name", "$$name", "ordinary prompt"] |
    all(.[]; test($pattern) | not)) and
  (["$name", "$0", "use $name"] | all(.[]; test($pattern)))
' >/dev/null || fail 'skills match accepted a non-name dollar sign'

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
sf_test_profile tooled '{"tools": ["beta", "alpha", "gamma", "delta", "epsilon"]}'
sf_profile_resolve_args -p tooled -m fixture
REPLY=$(jq -c '.profile' <<<"$REPLY")
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
sf_profile_resolve_args -p tooled -m fixture
profile=$(jq -c '.profile' <<<"$REPLY")
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
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=from-file' && $REPLY == ${SF_TEST_CONFIG:a} ]]
sf_environment_load
[[ ${(oj: :)SF_ENVIRONMENT_VALUES} == 'ANTHROPIC_API_KEY=other-file OPENAI_API_KEY=from-file' ]]
sf_environment_load ''
[[ ${#SF_ENVIRONMENT_VALUES} == 0 && $REPLY == ${SF_TEST_CONFIG:a} ]] ||
  fail 'an empty environment selection loaded credentials'
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
