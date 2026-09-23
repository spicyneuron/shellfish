#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/runtime.zsh lib/environment.zsh lib/session.zsh

typeset runtime tool_name
typeset -r fixture_backend="$ROOT/tests/fixtures/backend"
sf_test_tmp runtime
sf_test_config
mkdir -p "$tmp/home"
export HOME="${tmp:A}/home"

sf_test_profile work '{
  "backend": {"adapter": "@default/backends/openai"},
  "context_window": 128000,
  "request": {"model": "configured", "temperature": 0.2}
}'

# CLI request options override the profile.
sf_runtime_resolve_args -p work -m cli-model --request '{"temperature":0.7,"seed":4}'
runtime=$REPLY
jq -e --arg command "$ROOT/share/profiles/default/backends/openai/run" '
  .request == {model:"cli-model",temperature:0.7,seed:4} and
  .context_window == 128000 and
  .backend.command == $command and
  .backend.endpoint == "https://api.openai.com/v1/chat/completions" and
  .system == [] and
  .harness == {
    sandbox_read_paths:[],sandbox_write_paths:[],
    tools:[],sandbox:true,
    max_requests_per_turn:100,max_tool_calls_per_request:25,
    max_capture_bytes:32768
  }
' <<<"$runtime" >/dev/null

# A backend override replaces the adapter reference.
sf_runtime_resolve_args -p work -m cli-model -b @default/backends/openai-responses
jq -e '.backend.command | endswith("/share/profiles/default/backends/openai-responses/run")' \
  <<<"$REPLY" >/dev/null

# The bundled default profile supplies the coding agent.
sf_runtime_resolve_args -m default-model -b "$fixture_backend"
jq -e --arg root "$ROOT/share/profiles/default/hooks/session_start" \
  --arg prompt_root "$ROOT/share/profiles/default/hooks/user_prompt_submit" '
  (.harness.session_start | map(.command)) == [
    ($root + "/project_environment/run"),
    ($root + "/git_environment/run"),
    ($root + "/project_instructions/run")
  ] and
  .harness.user_prompt_submit[0].command == ($prompt_root + "/help/run") and
  .harness.user_prompt_submit[-1].command == ($prompt_root + "/git_environment/run") and
  (.harness.tools | map(.name)) ==
    ["read_file", "edit_file", "write_file", "skill", "search_web", "fetch_url", "shell"] and
  .harness.tools[0].manifest.render.permission_user_text == "${input.file_path}" and
  .harness.tools[1].manifest.render.preview_lines == "full" and
  (.harness.tools[0].manifest.render | has("preview_lines") | not) and
  .harness.tools[-1].manifest.render.user_text ==
    "${name}\n${input.command}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}"
' <<<"$REPLY" >/dev/null

# Bundled adapter names resolve through the bundled default profile.
sf_runtime_resolve_args -m gpt-codex-test -b codex
jq -e '.backend.command | endswith("/share/profiles/default/backends/codex/run")' \
  <<<"$REPLY" >/dev/null

# Presentation lives in tui.jsonc, so a profile has no place for it.
sf_test_profile bad-theme '{"theme_light":"missing"}'
if sf_runtime_resolve_args -p bad-theme -m model -b "$fixture_backend"; then
  fail 'presentation keys were accepted in a profile'
fi
[[ $SF_RUNTIME_ERROR == *'invalid profile at $["bad-theme"]["theme_light"]: unknown field'* ]]

# Absolute backend paths override configuration.
sf_runtime_resolve_args -p work -b "$fixture_backend"
jq -e '
  .backend.endpoint == "https://example.invalid/test" and
  (.backend.command | endswith("/tests/fixtures/backend/run"))
' <<<"$REPLY" >/dev/null

# A configured profile replaces the bundled file of the same name outright.
sf_test_profile default '{
  "backend": {"adapter": "'"$fixture_backend"'"},
  "request": {"model": "extended-model"},
  "tools": ["@default/tools/read_file"]
}'
sf_runtime_resolve_args
jq -e '
  .request == {model:"extended-model"} and
  (.harness.tools | map(.name)) == ["read_file"] and
  .system == [] and
  (.backend.command | endswith("/tests/fixtures/backend/run"))
' <<<"$REPLY" >/dev/null

# "..." splices the inherited list; repeated --profile composes left to right.
sf_test_profile extra '{"tools": ["...", "@default/tools/shell"]}'
sf_runtime_resolve_args -p default -p extra
jq -e '(.harness.tools | map(.name)) == ["read_file", "shell"]' <<<"$REPLY" >/dev/null

# A top-level list splices from a sibling too, and a token with nothing to splice drops.
sf_test_profile prompts '{"system": ["@default/system/general.md"]}'
sf_test_profile more-prompts '{"system": ["...", "@default/system/tools.md"],
  "tools": ["...", "@default/tools/shell"]}'
sf_runtime_resolve_args -p prompts -p more-prompts -m model -b "$fixture_backend"
jq -e '(.system | map(split("/") | last)) == ["general.md", "tools.md"] and
  (.harness.tools | map(.name)) == ["shell"]' <<<"$REPLY" >/dev/null

# Splicing a list that already holds the tool duplicates it.
sf_test_profile duplicate '{"tools": ["...", "@default/tools/read_file"]}'
if sf_runtime_resolve_args -p default -p duplicate; then
  fail 'duplicate tool references were accepted'
fi
[[ $SF_RUNTIME_ERROR == *'profile tools must be unique: @default/tools/read_file, @default/tools/read_file'* ]]

# "@default" is always the bundled file, so a configured default can build on it,
# and bundled profiles that extend the bare name see the configured one.
sf_test_profile default '{
  "extend": ["@default"],
  "backend": {"adapter": "'"$fixture_backend"'"},
  "request": {"model": "mine"}
}'
sf_runtime_resolve_args -p coding
jq -e '
  .request.model == "mine" and .request.max_tokens == 16384 and
  (.harness.tools | length) == 7 and
  (.harness.permission_request | map(.command | split("/")[-2])) == ["review"]
' <<<"$REPLY" >/dev/null

# Unknown and cyclic profiles fail.
if sf_runtime_resolve_args -p absent; then
  fail 'unknown profile was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'unknown profile: absent'* ]]
sf_test_profile loop-a '{"extend": ["loop-b"]}'
sf_test_profile loop-b '{"extend": ["loop-a"]}'
if sf_runtime_resolve_args -p loop-a; then
  fail 'profile inheritance cycle was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'profile inheritance cycle: loop-a'* ]]

# Missing config directories use bundled profiles.
(
  export XDG_CONFIG_HOME="$tmp/empty-config"
  sf_runtime_resolve_args -m test-model -b "$fixture_backend"
  jq -e '
    .request.model == "test-model" and
    (.backend.command | endswith("/tests/fixtures/backend/run"))
  ' <<<"$REPLY" >/dev/null
)

# Invalid backend paths fail.
if sf_runtime_resolve_args -p work -b "$tmp/not-a-backend"; then
  fail 'invalid backend path was accepted'
fi

# Malformed profiles identify their source.
sf_test_profile malformed '{"request":}'
if sf_runtime_resolve_args; then
  fail 'malformed profile was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid profile: '*'malformed/profile.jsonc:'*'parse error:'* ]]
rm -r "$SF_TEST_CONFIG/profiles/malformed"

# Home-relative sandbox paths expand safely.
sf_test_profile home-paths '{
  "extend": ["default"],
  "sandbox_read_paths": ["~/my reference"], "sandbox_write_paths": ["~/output"]
}'
sf_runtime_resolve_args -p home-paths -m test-model -b "$fixture_backend"
jq -e --arg read "${tmp:A}/home/my reference" --arg write "${tmp:A}/home/output" '
  .harness.sandbox_read_paths == [$read] and
  .harness.sandbox_write_paths == [$write]
' <<<"$REPLY" >/dev/null || fail 'home-relative sandbox paths were not expanded'
(
  unset HOME
  if sf_runtime_resolve_args -p home-paths -m test-model -b "$fixture_backend"; then
    fail 'home-relative sandbox path resolved without HOME'
  fi
  [[ $SF_RUNTIME_ERROR == *'cannot expand ~ without HOME'* ]]
)

# Hook references preserve order and read optional manifests and match scripts.
typeset hooked="$SF_TEST_CONFIG/profiles/hooked/hooks"
mkdir -p "$hooked/user_prompt_submit/help" "$hooked/user_prompt_submit/shell" "$hooked/stop/gate"
print -r -- '#!/bin/sh' >"$hooked/user_prompt_submit/help/run"
chmod +x "$hooked/user_prompt_submit/help/run"
cat >"$hooked/user_prompt_submit/help/manifest.jsonc" <<'JSON'
{
  "match": {"pattern": "^/(help|h)\\z"},
  "help": {
    "usage": "/help, /h",
    "description": "Show help"
  }
}
JSON
print -r -- '#!/bin/sh' >"$hooked/user_prompt_submit/shell/run"
chmod +x "$hooked/user_prompt_submit/shell/run"
# A match script beside run supersedes a manifest pattern.
print -r -- '#!/bin/sh' >"$hooked/user_prompt_submit/shell/match"
chmod +x "$hooked/user_prompt_submit/shell/match"
print -r -- '{"match":{"pattern":"^/shell\\z"}}' \
  >"$hooked/user_prompt_submit/shell/manifest.json"
print -r -- '#!/bin/sh' >"$hooked/stop/gate/run"
chmod +x "$hooked/stop/gate/run"
sf_test_profile hooked '{
  "backend": {"adapter": "'"$fixture_backend"'"},
  "request": {"model": "m"},
  "hooks": {"user_prompt_submit": ["help", "shell"], "stop": ["gate"]}
}'
sf_runtime_resolve_args -p hooked
jq -e --arg base "${hooked:A}" '
  .harness.user_prompt_submit == [
    {command:($base + "/user_prompt_submit/help/run"),
      match:{pattern:"^/(help|h)\\z"},help:{usage:"/help, /h",description:"Show help"}},
    {command:($base + "/user_prompt_submit/shell/run"),
      match:{command:($base + "/user_prompt_submit/shell/match")}}
  ] and .harness.stop ==
    [{command:($base + "/stop/gate/run")}]
' <<<"$REPLY" >/dev/null

# Only user_prompt_submit hooks may be gated by a match script.
print -r -- '#!/bin/sh' >"$hooked/stop/gate/match"
chmod +x "$hooked/stop/gate/match"
if sf_runtime_resolve_args -p hooked; then
  fail 'match script on a stop hook was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid hook component: '*'/stop/gate/run'* ]]
rm "$hooked/stop/gate/match"

# A reference that names a file rather than a component directory fails.
rm -r "$hooked/stop/gate"
print -r -- '#!/bin/sh' >"$hooked/stop/gate"
if sf_runtime_resolve_args -p hooked; then
  fail 'non-directory hook was accepted'
fi
[[ $SF_RUNTIME_ERROR == 'invalid hooks/stop reference: gate' ]]

# Tool references preserve configured order.
typeset tools="$SF_TEST_CONFIG/profiles/tooled/tools"
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
sf_runtime_resolve_args -p tooled
jq -e --arg base "${tools:A}" '
  (.harness.tools | map(.name)) == ["beta", "alpha", "gamma", "delta", "epsilon"] and
  (.harness.tools | map(.command)) == [($base + "/beta/run"), ($base + "/alpha/run"),
    ($base + "/gamma/run"), ($base + "/delta/run"), ($base + "/epsilon/run")] and
  all(.harness.tools[]; .settings == null and (has("describe") | not) and
    .manifest.render == {initial_user_text:"${name} ${input}",
      user_text:"${name} ${input}\n${output.stdout}${output.stderr}",
      model_text:"${output.stdout}${output.stderr}",permission_user_text:"${input}"}) and
  .harness.tools[0].manifest.description == "beta tool"
' <<<"$REPLY" >/dev/null
cp "$tools/beta/manifest.jsonc" "$tools/beta/manifest.json"
if sf_runtime_resolve_args -p tooled; then
  fail 'component with ambiguous manifests was accepted'
fi
[[ $SF_RUNTIME_ERROR == "multiple component manifests: ${tools:A}/beta" ]]
rm "$tools/beta/manifest.json"

# Sandboxed tools require fence settings.
jq -n '{description:"sandboxed",input_schema:{type:"object"},sandbox:true}' \
  >"$tools/alpha/manifest.json"
if sf_runtime_resolve_args -p tooled; then
  fail 'sandboxed tool without fence settings was accepted'
fi
[[ $SF_RUNTIME_ERROR == *"cannot read tool sandbox settings: ${tools:A}/alpha/fence.jsonc"* ]]
print -r -- '{}' >"$tools/alpha/fence.jsonc"
sf_runtime_resolve_args -p tooled
jq -e --arg settings "${tools:A}/alpha/fence.jsonc" '
  (.harness.tools | map(.name)) == ["beta", "alpha", "gamma", "delta", "epsilon"] and
  .harness.tools[1].manifest.sandbox == true and
  .harness.tools[1].settings == $settings' <<<"$REPLY" >/dev/null


sf_test_profile unsandboxed '{"extend": ["tooled"], "sandbox": false}'
sf_runtime_resolve_args -p unsandboxed
jq -e '.harness.sandbox == false' <<<"$REPLY" >/dev/null

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

# Exported values win: selected names carry them, and a full load leaves them
# to inheritance.
export OPENAI_API_KEY=''
sf_environment_load OPENAI_API_KEY
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=' ]]
sf_environment_load
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'ANTHROPIC_API_KEY=other-file' ]]
unset OPENAI_API_KEY

print -r -- 'invalid line' >>"$environment_file"
if sf_environment_load OPENAI_API_KEY; then
  fail 'invalid env file tail was accepted'
fi
