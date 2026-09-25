#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/profile.zsh lib/environment.zsh lib/session.zsh

typeset profile tool_name
typeset -r fixture_backend="$ROOT/tests/fixtures/backend"
sf_test_tmp profile
sf_test_config
mkdir -p "$tmp/home"
export HOME="${tmp:A}/home"

sf_test_profile work '{
  "backend": {"adapter": "@backends/openai"},
  "context_window": 128000,
  "request": {"model": "configured", "temperature": 0.2}
}'

# Nested names select by relative path and can extend other nested profiles.
sf_test_profile openai/base '{"extend":["@default"],"request":{"model":"base"}}'
sf_test_profile openai/sol '{"extend":["openai/base"],"request":{"model":"sol"},
  "system":["prompt.md"],"hooks":{"stop":["stop"]}}'
mkdir -p "$SF_TEST_CONFIG/system" "$SF_TEST_CONFIG/hooks"
print -r -- 'nested' >"$SF_TEST_CONFIG/system/prompt.md"
print -r -- '#!/bin/sh' >"$SF_TEST_CONFIG/hooks/stop"
chmod +x "$SF_TEST_CONFIG/hooks/stop"
sf_profile_resolve_args -p openai/sol
jq -e --arg root "${SF_TEST_CONFIG:A}" '
  .request.model == "sol" and (.tools | length) == 7 and
  .system == [$root + "/system/prompt.md"] and
  .hooks.stop == [$root + "/hooks/stop"]' <<<"$REPLY" >/dev/null
for name in openai//sol openai/../sol /openai/sol openai/sol/; do
  if sf_profile_resolve_args -p "$name"; then
    fail "invalid profile name was accepted: $name"
  fi
done

# CLI request options override the profile.
sf_profile_resolve_args -p work -m cli-model --request '{"temperature":0.7,"seed":4}'
profile=$REPLY
jq -e --arg adapter "$ROOT/share/backends/openai" '
  .request == {model:"cli-model",temperature:0.7,seed:4} and
  .context_window == 128000 and
  .backend == {adapter:$adapter,endpoint:"https://api.openai.com/v1/chat/completions",
    insecure_tls:false,http_timeout:3600,http_stall:300} and
  del(.request, .context_window, .backend) == {
    system:[],tools:[],hooks:{},env:{},sandbox:true,sandbox_read_paths:[],sandbox_write_paths:[],
    max_requests_per_turn:100,max_tool_calls_per_request:25,max_capture_bytes:32768
  }
' <<<"$profile" >/dev/null

# A backend override replaces the adapter reference.
sf_profile_resolve_args -p work -m cli-model -b @backends/openai-responses
jq -e '.backend.adapter | endswith("/share/backends/openai-responses")' \
  <<<"$REPLY" >/dev/null

# The bundled default profile supplies the coding agent.
sf_profile_resolve_args -m default-model -b "$fixture_backend"
jq -e --arg root "$ROOT/share/hooks" '
  .hooks.session_start == [$root + "/project_environment", $root + "/git_environment",
    $root + "/project_instructions"] and
  .hooks.user_prompt_submit == [$root + "/user_prompt_submit"] and
  (.hooks | has("permission_request") | not) and
  (.tools | map(split("/") | last)) ==
    ["read_file", "edit_file", "write_file", "skill", "search_web", "fetch_url", "shell"]
' <<<"$REPLY" >/dev/null
# Tool manifests are read live from the resolved folders.
sf_profile_tools "$REPLY"
jq -e '
  .[0].manifest.user_permission == "${input.file_path}" and
  .[-1].manifest.user_text == "${name}\n${input.command}"
' <<<"$REPLY" >/dev/null

# Bundled adapter names resolve through the bundled default profile.
sf_profile_resolve_args -m gpt-codex-test -b codex
jq -e '.backend.adapter | endswith("/share/backends/codex")' \
  <<<"$REPLY" >/dev/null

# Presentation lives in tui.jsonc, so a profile has no place for it.
sf_test_profile bad-theme '{"theme_light":"missing"}'
if sf_profile_resolve_args -p bad-theme -m model -b "$fixture_backend"; then
  fail 'presentation keys were accepted in a profile'
fi
[[ $SF_PROFILE_ERROR == *'invalid profile at $["bad-theme"]["theme_light"]: unknown field'* ]]

# Absolute backend paths override configuration.
sf_profile_resolve_args -p work -b "$fixture_backend"
jq -e '
  .backend.endpoint == "https://example.invalid/test" and
  (.backend.adapter | endswith("/tests/fixtures/backend"))
' <<<"$REPLY" >/dev/null

# A configured profile replaces the bundled file of the same name outright.
sf_test_profile default '{
  "backend": {"adapter": "'"$fixture_backend"'"},
  "request": {"model": "extended-model"},
  "tools": ["@tools/read_file"]
}'
sf_profile_resolve_args
jq -e '
  .request == {model:"extended-model"} and
  (.tools | map(split("/") | last)) == ["read_file"] and
  .system == [] and
  (.backend.adapter | endswith("/tests/fixtures/backend"))
' <<<"$REPLY" >/dev/null

# "..." splices the inherited list; repeated --profile composes left to right.
sf_test_profile extra '{"tools": ["...", "@tools/shell"]}'
sf_profile_resolve_args -p default -p extra
jq -e '(.tools | map(split("/") | last)) == ["read_file", "shell"]' <<<"$REPLY" >/dev/null

# A top-level list splices from a sibling too, and a token with nothing to splice drops.
sf_test_profile prompts '{"system": ["@system/general.md"]}'
sf_test_profile more-prompts '{"system": ["...", "@system/tools.md"],
  "tools": ["...", "@tools/shell"]}'
sf_profile_resolve_args -p prompts -p more-prompts -m model -b "$fixture_backend"
jq -e '(.system | map(split("/") | last)) == ["general.md", "tools.md"] and
  (.tools | map(split("/") | last)) == ["shell"]' <<<"$REPLY" >/dev/null

# Splicing a list that already holds the tool duplicates it.
sf_test_profile duplicate '{"tools": ["...", "@tools/read_file"]}'
if sf_profile_resolve_args -p default -p duplicate; then
  fail 'duplicate tool references were accepted'
fi
[[ $SF_PROFILE_ERROR == *'profile tools must be unique: @tools/read_file, @tools/read_file'* ]]

# "@default" is always the bundled file, so a configured default can build on it,
# and bundled profiles that extend the bare name see the configured one.
sf_test_profile default '{
  "extend": ["@default"],
  "backend": {"adapter": "'"$fixture_backend"'"},
  "request": {"model": "mine"}
}'
sf_profile_resolve_args -p coding
jq -e '
  .request.model == "mine" and .request.max_tokens == 16384 and
  (.tools | length) == 7 and
  (.hooks.permission_request | map(split("/")[-2:] | join("/"))) == ["hooks/review"]
' <<<"$REPLY" >/dev/null

# Unknown and cyclic profiles fail.
if sf_profile_resolve_args -p absent; then
  fail 'unknown profile was accepted'
fi
[[ $SF_PROFILE_ERROR == *'unknown profile: absent'* ]]
sf_test_profile loop-a '{"extend": ["loop-b"]}'
sf_test_profile loop-b '{"extend": ["loop-a"]}'
if sf_profile_resolve_args -p loop-a; then
  fail 'profile inheritance cycle was accepted'
fi
[[ $SF_PROFILE_ERROR == *'profile inheritance cycle: loop-a'* ]]

# Missing config directories use bundled profiles.
(
  export XDG_CONFIG_HOME="$tmp/empty-config"
  sf_profile_resolve_args -m test-model -b "$fixture_backend"
  jq -e '
    .request.model == "test-model" and
    (.backend.adapter | endswith("/tests/fixtures/backend"))
  ' <<<"$REPLY" >/dev/null
)

# Invalid backend paths fail.
if sf_profile_resolve_args -p work -b "$tmp/not-a-backend"; then
  fail 'invalid backend path was accepted'
fi

# Malformed profiles identify their source.
sf_test_profile malformed '{"request":}'
if sf_profile_resolve_args -p malformed; then
  fail 'malformed profile was accepted'
fi
[[ $SF_PROFILE_ERROR == *'invalid profile: '*'malformed.jsonc:'*'parse error:'* ]]
rm "$SF_TEST_CONFIG/profiles/malformed.jsonc"

# Home-relative sandbox paths expand safely.
sf_test_profile home-paths '{
  "extend": ["default"],
  "sandbox_read_paths": ["~/my reference"], "sandbox_write_paths": ["~/output"]
}'
sf_profile_resolve_args -p home-paths -m test-model -b "$fixture_backend"
jq -e --arg read "${tmp:A}/home/my reference" --arg write "${tmp:A}/home/output" '
  .sandbox_read_paths == [$read] and
  .sandbox_write_paths == [$write]
' <<<"$REPLY" >/dev/null || fail 'home-relative sandbox paths were not expanded'
(
  unset HOME
  if sf_profile_resolve_args -p home-paths -m test-model -b "$fixture_backend"; then
    fail 'home-relative sandbox path resolved without HOME'
  fi
  [[ $SF_PROFILE_ERROR == *'cannot expand ~ without HOME'* ]]
)

# Inactive files, including old folder-style hooks and manifests, are inert.
typeset hooks="$SF_TEST_CONFIG/hooks"
mkdir -p "$hooks/dir" "$SF_TEST_CONFIG/profiles/hooked/hooks" \
  "$SF_TEST_CONFIG/profiles/hooked/tools/legacy"
print -r -- '#!/bin/sh' >"$SF_TEST_CONFIG/profiles/hooked/hooks/stop"
chmod +x "$SF_TEST_CONFIG/profiles/hooked/hooks/stop"
print -r -- 'not json' >"$SF_TEST_CONFIG/profiles/hooked/tools/legacy/manifest.jsonc"
for script in "$hooks/first" "$hooks/second"; do
  print -r -- '#!/bin/sh' >"$script"
  chmod +x "$script"
done
sf_test_profile hook-base '{"backend":{"adapter":"'"$fixture_backend"'"},
  "request":{"model":"m"},"hooks":{"stop":["first"]}}'
sf_test_profile hooked '{"extend":["hook-base"],"hooks":{"stop":["...","second"]}}'
sf_profile_resolve_args -p hooked
jq -e --arg hooks "${hooks:A}" '
  .hooks.stop == [$hooks + "/first", $hooks + "/second"] and
  (.hooks | has("user_prompt_submit") | not)
' <<<"$REPLY" >/dev/null || fail 'explicit hook order changed'
sf_test_profile hooked '{"extend":["hook-base"],"hooks":{"stop":[]}}'
sf_profile_resolve_args -p hooked
jq -e '.hooks.stop == []' <<<"$REPLY" >/dev/null ||
  fail 'an empty hook list did not disable the lifecycle'

# A hook reference must name an executable file.
sf_test_profile hooked '{"extend":["hook-base"],"hooks":{"pre_tool_use":["dir"]}}'
if sf_profile_resolve_args -p hooked; then
  fail 'directory hook was accepted'
fi
[[ $SF_PROFILE_ERROR == 'invalid hooks reference: dir' ]]

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
sf_test_profile tooled '{
  "backend": {"adapter": "'"$fixture_backend"'"},
  "request": {"model": "m"},
  "tools": ["beta", "alpha", "gamma", "delta", "epsilon"]
}'
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

sf_test_profile unsandboxed '{"extend": ["tooled"], "sandbox": false}'
sf_profile_resolve_args -p unsandboxed
jq -e '.sandbox == false' <<<"$REPLY" >/dev/null

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

# Profile env merges by key and overrides .env.
sf_test_profile env-base '{"extend":["work"],"env":{"OPENAI_API_KEY":"base","OTHER":"kept"}}'
sf_test_profile env-child '{"extend":["env-base"],"env":{"OPENAI_API_KEY":"profile"}}'
sf_profile_resolve_args -p env-child
profile=$REPLY
jq -e '.env == {OPENAI_API_KEY:"profile",OTHER:"kept"}' <<<"$profile" >/dev/null
sf_environment_load OPENAI_API_KEY "$(jq -c '.env' <<<"$profile")"
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=profile' ]]
sf_environment_load '' "$(jq -c '.env' <<<"$profile")"
[[ ${SF_ENVIRONMENT_VALUES[(Ie)ANTHROPIC_API_KEY=other-file]} -gt 0 &&
   ${SF_ENVIRONMENT_VALUES[(Ie)OPENAI_API_KEY=profile]} -gt 0 &&
   ${SF_ENVIRONMENT_VALUES[(Ie)OTHER=kept]} -gt 0 && ${#SF_ENVIRONMENT_VALUES} == 3 ]]
sf_environment_load OTHER '{"OTHER":"line one\nline two\n"}'
[[ $SF_ENVIRONMENT_VALUES[1] == $'OTHER=line one\nline two\n' ]]

# Exported values win: selected names carry them, and a full load leaves them
# to inheritance.
export OPENAI_API_KEY=''
sf_environment_load OPENAI_API_KEY '{"OPENAI_API_KEY":"profile"}'
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=' ]]
sf_environment_load '' '{"OPENAI_API_KEY":"profile"}'
[[ ${(oj: :)SF_ENVIRONMENT_VALUES} == 'ANTHROPIC_API_KEY=other-file' ]]
unset OPENAI_API_KEY

for value in '{"BAD-NAME":"x"}' '{"GOOD":2}' '{"GOOD":"\u0000"}'; do
  sf_test_profile bad-env '{"extend":["work"],"env":'"$value"'}'
  if sf_profile_resolve_args -p bad-env; then
    fail "invalid profile env was accepted: $value"
  fi
done

print -r -- 'invalid line' >>"$environment_file"
if sf_environment_load OPENAI_API_KEY; then
  fail 'invalid env file tail was accepted'
fi
