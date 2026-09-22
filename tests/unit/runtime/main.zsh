#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/runtime.zsh lib/environment.zsh lib/session.zsh

typeset config runtime tool_name hook
sf_test_tmp runtime
mkdir -p "$tmp/config" "$tmp/home"
export HOME="${tmp:A}/home"
unset XDG_CONFIG_HOME
config="$tmp/config/shellfish.jsonc"

cat >"$config" <<'JSON'
{
  "default_profile": "work",
  "backends": {
    "custom": {"adapter": "openai"},
    "custom-responses": {"adapter": "openai-responses"}
  },
  "profiles": {
    "work": {
      "backend": "custom",
      "context_window": 128000,
      "request": {"model": "configured", "temperature": 0.2}
    }
  }
}
JSON

# CLI request options override the profile.
sf_runtime_resolve_from_config "$config" '' 'cli-model' '{"temperature":0.7,"seed":4}'
runtime=$REPLY
jq -e --arg command "$ROOT/share/default/backends/openai/run" '
  .profile.request == {model:"cli-model",temperature:0.7,seed:4} and
  .profile.context_window == 128000 and
  .backend.name == "custom" and
  .backend.command == $command and
  (.backend.context_window_command | endswith("/share/default/backends/openai/context_window")) and
  (.backend.env_file | endswith("/config/.env")) and
  .backend.endpoint == "https://api.openai.com/v1/chat/completions" and
  .backend.environment == ["OPENAI_API_KEY"] and
  .profile.system == [] and
  .harness == {
    sandbox_read_paths:[],sandbox_write_paths:[],
    fence:"",tools:[],sandbox:true,
    max_requests_per_turn:100,max_tool_calls_per_request:25,
    max_capture_bytes:32768
  }
' <<<"$runtime" >/dev/null

# Backend overrides select their adapter.
sf_runtime_resolve_from_config "$config" '' 'cli-model' '{}' custom-responses
jq -e '
  .backend.name == "custom-responses" and
  (.backend.context_window_command |
    endswith("/share/default/backends/openai-responses/context_window"))
' <<<"$REPLY" >/dev/null

# Empty configs use bundled defaults.
print -r -- '{}' >"$tmp/config/empty.jsonc"
sf_runtime_resolve_from_config "$tmp/config/empty.jsonc" '' 'default-model' '{}' \
  "$ROOT/tests/fixtures/backend"
jq -e --arg root "$ROOT/share/default/hooks/session_start" \
  --arg prompt_root "$ROOT/share/default/hooks/user_prompt_submit" '
  (.harness.session_start | map(.command)) == [
    ($root + "/project_environment/run"),
    ($root + "/git_environment/run"),
    ($root + "/project_instructions/run")
  ] and
  (.harness.user_prompt_submit[0] |
    .command == ($prompt_root + "/help/run") and
    .render == {initial_user_text:"",user_text:"${output.stdout}${output.stderr}",
      model_text:"",preview_lines:"full"}) and
  .harness.user_prompt_submit[-1].command == ($prompt_root + "/git_environment/run") and
  (.backend | has("context_window_command") | not) and
  (.harness.tools | map(.name)) ==
    ["read_file", "edit_file", "write_file", "skill", "search_web", "fetch_url", "shell"] and
  .harness.tools[0].manifest.render.permission_user_text == "${input.file_path}" and
  .harness.tools[1].manifest.render.preview_lines == "full" and
  (.harness.tools[0].manifest.render | has("preview_lines") | not) and
  .harness.tools[-1].manifest.render.user_text ==
    "${name}\n${input.command}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}"
' <<<"$REPLY" >/dev/null

# Bundled backend names resolve adapters.
sf_runtime_resolve_from_config "$tmp/config/empty.jsonc" '' 'gpt-codex-test' '{}' codex
jq -e '
  .backend.name == "codex" and
  (.backend.context_window_command | endswith("/share/default/backends/codex/context_window"))
' <<<"$REPLY" >/dev/null

# A runtime carries no presentation, and an unusable theme cannot block one.
print -r -- '{"theme_light":"missing","themes":{"dark":{"text":"blue"}}}' \
  >"$tmp/config/bad-theme.jsonc"
sf_runtime_resolve_from_config "$tmp/config/bad-theme.jsonc" '' 'model' '{}' \
  "$ROOT/tests/fixtures/backend" || fail 'runtime resolution read presentation'
jq -e '.profile.request.model == "model" and (has("presentation") | not)' \
  <<<"$REPLY" >/dev/null

# CLI backend paths override configuration.
sf_runtime_resolve_from_config "$config" work '' '{}' "$ROOT/tests/fixtures/backend"
jq -e '
  .backend.endpoint == "https://example.invalid/test" and
  (.backend.command | endswith("/tests/fixtures/backend/run"))
' <<<"$REPLY" >/dev/null

# Relative backend paths use the caller directory.
mkdir -p "$tmp/fixtures"
ln -s "$ROOT/tests/fixtures/backend" "$tmp/fixtures/backend"
(
  cd "$tmp"
  sf_runtime_resolve_from_config "$config" work '' '{}' fixtures/backend
  jq -e --arg command "$ROOT/tests/fixtures/backend/run" \
    '.backend.command == $command' <<<"$REPLY" >/dev/null
)

# Default profiles can extend bundled defaults.
cat >"$tmp/config/default-extend.jsonc" <<JSON
{
  "profiles": {
    "default": {
      "extend": "default",
      "backend": "test",
      "request": {"model": "extended-model"}
    }
  },
  "backends": {"test": {"adapter": "$ROOT/tests/fixtures/backend"}}
}
JSON
sf_runtime_resolve_from_config "$tmp/config/default-extend.jsonc" '' '' '{}'
jq -e '
  .profile.request.model == "extended-model" and
  (.backend.command | endswith("/tests/fixtures/backend/run"))
' <<<"$REPLY" >/dev/null

# Missing default configs use bundled defaults.
mkdir "$tmp/empty-config"
(
  export XDG_CONFIG_HOME="$tmp/empty-config"
  sf_runtime_resolve_from_config '' '' test-model '{}' "$ROOT/tests/fixtures/backend"
  jq -e '
    .profile.request.model == "test-model" and
    (.backend.command | endswith("/tests/fixtures/backend/run"))
  ' <<<"$REPLY" >/dev/null
)

# Invalid backend paths fail.
if sf_runtime_resolve_from_config "$config" work '' '{}' "$tmp/not-a-backend"; then
  fail 'invalid CLI backend path was accepted'
fi

# Config errors identify their source.
if sf_runtime_resolve_from_config "$tmp/missing.jsonc" '' '' '{}'; then
  fail 'explicit missing config was accepted'
fi
sf_runtime_config_path "$tmp/missing.jsonc"
[[ $SF_RUNTIME_ERROR == "cannot read config: $REPLY" ]]

cat >"$tmp/config/malformed.jsonc" <<'JSON'
{"profiles":}
JSON
if sf_runtime_resolve_from_config "$tmp/config/malformed.jsonc" '' '' '{}'; then
  fail 'malformed config was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid config: '*'malformed.jsonc:'*'parse error:'* ]]

# Home-relative sandbox paths expand safely.
cat >"$tmp/config/home-paths.jsonc" <<'JSON'
{
  "profiles":{"default":{"extend":"default","harness":"home"}},
  "harnesses":{"home":{
    "sandbox_read_paths":["~/reference"],
    "sandbox_write_paths":["~/output"]
  }}
}
JSON
HOME="$tmp/home" sf_runtime_resolve_from_config "$tmp/config/home-paths.jsonc" '' \
  test-model '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg read "${tmp:A}/home/reference" --arg write "${tmp:A}/home/output" '
  .harness.sandbox_read_paths == [$read] and
  .harness.sandbox_write_paths == [$write]
' <<<"$REPLY" >/dev/null || fail 'home-relative sandbox paths were not expanded'
(
  unset HOME
  if sf_runtime_resolve_from_config "$tmp/config/home-paths.jsonc" '' test-model '{}' \
    "$ROOT/tests/fixtures/backend"; then
    fail 'home-relative sandbox path resolved without HOME'
  fi
  [[ $SF_RUNTIME_ERROR == *'cannot expand ~ without HOME'* ]]
)

# Hook references preserve order and prefer configured scripts.
mkdir -p "$tmp/config/hooks/user_prompt_submit/help" \
  "$tmp/config/hooks/user_prompt_submit/shell" "$tmp/config/hooks/stop/gate"
print -r -- '#!/bin/sh' >"$tmp/config/hooks/user_prompt_submit/help/run"
chmod +x "$tmp/config/hooks/user_prompt_submit/help/run"
cat >"$tmp/config/hooks/user_prompt_submit/help/manifest.jsonc" <<'JSON'
{
  // Imported only for this component.
  "environment": ["HELP_FORMAT"],
  "render": {"user_text": "${output.stdout}"},
  "match": {"pattern": "^/(help|h)\\z"},
  "help": {
    "usage": "/help, /h",
    "description": "Show help"
  }
}
JSON
print -r -- '#!/bin/sh' >"$tmp/config/hooks/user_prompt_submit/shell/run"
chmod +x "$tmp/config/hooks/user_prompt_submit/shell/run"
# A match script beside run supersedes a manifest pattern.
print -r -- '#!/bin/sh' >"$tmp/config/hooks/user_prompt_submit/shell/match"
chmod +x "$tmp/config/hooks/user_prompt_submit/shell/match"
print -r -- '{"match":{"pattern":"^/shell\\z"}}' \
  >"$tmp/config/hooks/user_prompt_submit/shell/manifest.json"
print -r -- '#!/bin/sh' >"$tmp/config/hooks/stop/gate/run"
chmod +x "$tmp/config/hooks/stop/gate/run"
cat >"$tmp/config/hooked.jsonc" <<JSON
{
  "profiles": {"default": {"harness": "hooked", "request": {"model": "m"}}},
  "harnesses": {"hooked": {
    "user_prompt_submit": ["help", "shell"],
    "stop": ["gate"]
  }}
}
JSON
sf_runtime_resolve_from_config "$tmp/config/hooked.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg base "${tmp:A}/config/hooks" '
  .harness.user_prompt_submit == [
    {command:($base + "/user_prompt_submit/help/run"),render:{initial_user_text:"",user_text:"${output.stdout}",model_text:"${output.stdout}"},environment:["HELP_FORMAT"],
      match:{pattern:"^/(help|h)\\z"},help:{usage:"/help, /h",description:"Show help"}},
    {command:($base + "/user_prompt_submit/shell/run"),render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"},environment:[],
      match:{command:($base + "/user_prompt_submit/shell/match")}}
  ] and .harness.stop ==
    [{command:($base + "/stop/gate/run"),render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"},environment:[]}]
' <<<"$REPLY" >/dev/null

# Only user_prompt_submit hooks may be gated by a match script.
print -r -- '#!/bin/sh' >"$tmp/config/hooks/stop/gate/match"
chmod +x "$tmp/config/hooks/stop/gate/match"
if sf_runtime_resolve_from_config "$tmp/config/hooked.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"; then
  fail 'match script on a stop hook was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid hook component: '*'/stop/gate/run'* ]]
rm "$tmp/config/hooks/stop/gate/match"

# Components resolve beside a symlinked config's target.
mkdir -p "$tmp/symlink-config-home/shellfish" "$tmp/config-target/system"
print -r -- 'linked prompt' >"$tmp/config-target/system/linked.md"
cat >"$tmp/config-target/shellfish.jsonc" <<'JSON'
{
  "profiles":{"default":{"system":["linked.md"],"request":{"model":"m"}}}
}
JSON
ln -s "$tmp/config-target/shellfish.jsonc" \
  "$tmp/symlink-config-home/shellfish/shellfish.jsonc"
(
  export XDG_CONFIG_HOME="$tmp/symlink-config-home"
  sf_runtime_resolve_from_config '' '' '' '{}' "$ROOT/tests/fixtures/backend"
  jq -e --arg env "${tmp:A}/config-target/.env" \
    --arg path "${tmp:A}/config-target/system/linked.md" '
    .profile.system == [$path] and .backend.env_file == $env
  ' <<<"$REPLY" >/dev/null
)

# System references resolve without reading prompt files.
mkdir -p "$tmp/config/system"
print -r -- 'first' >"$tmp/config/system/first.md"
print -r -- 'second' >"$tmp/config/system/second.md"
cat >"$tmp/config/system.jsonc" <<'JSON'
{
  "profiles":{"default":{"system":["first.md","second.md"],"request":{"model":"m"}}}
}
JSON
sf_runtime_resolve_from_config "$tmp/config/system.jsonc" '' '' '{}' \
  "$ROOT/tests/fixtures/backend"
jq -e --arg first "${tmp:A}/config/system/first.md" \
  --arg second "${tmp:A}/config/system/second.md" \
  '.profile.system == [$first,$second]' <<<"$REPLY" >/dev/null ||
  fail 'system component paths were not resolved'
rm "$tmp/config/system/second.md"
sf_runtime_resolve_from_config "$tmp/config/system.jsonc" '' '' '{}' \
  "$ROOT/tests/fixtures/backend" || fail 'config tried to read a missing prompt file'
jq -e --arg fallback "$ROOT/share/default/system/second.md" \
  '.profile.system[1] == $fallback' <<<"$REPLY" >/dev/null ||
  fail 'missing prompt path was not resolved'

# Missing hook references fail.
cat >"$tmp/config/missing-hook.jsonc" <<'JSON'
{
  "profiles":{"default":{"harness":"bad","request":{"model":"m"}}},
  "harnesses":{"bad":{"stop":["missing"]}}
}
JSON
if sf_runtime_resolve_from_config "$tmp/config/missing-hook.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"; then
  fail 'missing hook was accepted'
fi
[[ $SF_RUNTIME_ERROR == 'invalid stop hook: missing' ]]

# Configured scripts override bundled scripts.
mkdir -p "$tmp/root/share/default/hooks/stop/bundled" "$tmp/hooks/stop/bundled"
ln -s "$ROOT/lib" "$tmp/root/lib"
ln -s "$ROOT/libexec" "$tmp/root/libexec"
ln -s "$ROOT/share/default/shellfish.jsonc" "$tmp/root/share/default/shellfish.jsonc"
print -r -- '#!/bin/sh' >"$tmp/root/share/default/hooks/stop/bundled/run"
chmod +x "$tmp/root/share/default/hooks/stop/bundled/run"
print -r -- '#!/bin/sh' >"$tmp/hooks/stop/bundled/run"
chmod +x "$tmp/hooks/stop/bundled/run"
cat >"$tmp/bundled.jsonc" <<'JSON'
{
  "profiles":{"default":{"harness":"fallback","request":{"model":"m"}}},
  "harnesses":{"fallback":{"stop":["bundled"]}}
}
JSON
SF_ROOT="$tmp/root"
SF_SHARE="$tmp/root/share"
sf_runtime_resolve_from_config "$tmp/bundled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg path "${tmp:A}/hooks/stop/bundled/run" \
  '.harness.stop == [{command:$path,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"},environment:[]}]' <<<"$REPLY" >/dev/null
rm -rf -- "$tmp/hooks/stop/bundled"
sf_runtime_resolve_from_config "$tmp/bundled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg path "${tmp:A}/root/share/default/hooks/stop/bundled/run" \
  '.harness.stop == [{command:$path,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"},environment:[]}]' <<<"$REPLY" >/dev/null
SF_ROOT=$ROOT
SF_SHARE=$ROOT/share

# Tool references preserve configured order.
mkdir -p "$tmp/config/tools"
for tool_name in alpha beta gamma delta epsilon; do
  mkdir "$tmp/config/tools/$tool_name"
  print -r -- '#!/bin/sh' >"$tmp/config/tools/$tool_name/run"
  chmod +x "$tmp/config/tools/$tool_name/run"
  jq -n --arg description "$tool_name tool" \
    '{description:$description,input_schema:{type:"object"},sandbox:false}' \
    >"$tmp/config/tools/$tool_name/manifest.json"
done
mv "$tmp/config/tools/beta/manifest.json" "$tmp/config/tools/beta/manifest.jsonc"
cat >"$tmp/config/tooled.jsonc" <<'JSON'
{
  "profiles":{"default":{"harness":"tooled","request":{"model":"m"}}},
  "harnesses":{"tooled":{"tools":["beta","alpha","gamma","delta","epsilon"]}}
}
JSON
sf_runtime_resolve_from_config "$tmp/config/tooled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg base "${tmp:A}/config/tools" '
  (.harness.tools | map(.name)) == ["beta", "alpha", "gamma", "delta", "epsilon"] and
  (.harness.tools | map(.command)) == [($base + "/beta/run"), ($base + "/alpha/run"),
    ($base + "/gamma/run"), ($base + "/delta/run"), ($base + "/epsilon/run")] and
  all(.harness.tools[]; .settings == null and (has("describe") | not) and
    .manifest.render == {initial_user_text:"${name} ${input}",
      user_text:"${name} ${input}\n${output.stdout}${output.stderr}",
      model_text:"${output.stdout}${output.stderr}",permission_user_text:"${input}"}) and
  .harness.tools[0].manifest.description == "beta tool"
' <<<"$REPLY" >/dev/null
cp "$tmp/config/tools/beta/manifest.jsonc" "$tmp/config/tools/beta/manifest.json"
if sf_runtime_resolve_from_config "$tmp/config/tooled.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"; then
  fail 'component with ambiguous manifests was accepted'
fi
[[ $SF_RUNTIME_ERROR == "multiple component manifests: ${tmp:A}/config/tools/beta" ]]
rm "$tmp/config/tools/beta/manifest.json"

# Sandboxed tools require fence settings.
jq -n '{description:"sandboxed",input_schema:{type:"object"},sandbox:true}' \
  >"$tmp/config/tools/alpha/manifest.json"
if sf_runtime_resolve_from_config "$tmp/config/tooled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"; then
  fail 'sandboxed tool without fence settings was accepted'
fi
[[ $SF_RUNTIME_ERROR == *"cannot read tool sandbox settings: ${tmp:A}/config/tools/alpha/fence.jsonc"* ]]
print -r -- '{}' >"$tmp/config/tools/alpha/fence.jsonc"
sf_runtime_resolve_from_config "$tmp/config/tooled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg settings "${tmp:A}/config/tools/alpha/fence.jsonc" '
  (.harness.tools | map(.name)) == ["beta", "alpha", "gamma", "delta", "epsilon"] and
  .harness.tools[1].manifest.sandbox == true and
  .harness.tools[1].settings == $settings' <<<"$REPLY" >/dev/null

(
  commands[fence]=''
  if sf_runtime_resolve_from_config "$tmp/config/tooled.jsonc" '' '' '{}' \
      "$ROOT/tests/fixtures/backend"; then
    fail 'sandboxed tool without fence was accepted'
  fi
  [[ $SF_RUNTIME_ERROR == *'sandboxing requires fence'* ]]
)

# Unsandboxed harnesses do not require fence.
jq '.harnesses.tooled.sandbox=false' "$tmp/config/tooled.jsonc" \
  >"$tmp/config/unsandboxed-tools.jsonc"
(
  unset 'commands[fence]'
  sf_runtime_resolve_from_config "$tmp/config/unsandboxed-tools.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"
  jq -e '.harness.sandbox == false and .harness.fence == ""' <<<"$REPLY" >/dev/null
)

# Exported environment values override the env file.
export OPENAI_API_KEY='from-environment'
export ANTHROPIC_API_KEY='other-component'
sf_runtime_resolve_from_config "$config" work '' '{}'
runtime=$(jq -c '.harness.stop=[{command:"/bin/hook",environment:["ANTHROPIC_API_KEY"],render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]' \
  <<<"$REPLY")
typeset declared
declared=$(jq -L "$ROOT" -rn --argjson runtime "$runtime" \
  'include "lib/runtime"; declared_environment($runtime)')
[[ $declared == 'ANTHROPIC_API_KEY OPENAI_API_KEY' ]]
sf_environment_load "$(jq -r '.backend.env_file' <<<"$runtime")" OPENAI_API_KEY
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=from-environment' ]]
[[ $runtime != *from-environment* ]]
unset OPENAI_API_KEY ANTHROPIC_API_KEY

# Environment values load from env files.
typeset environment_file="$tmp/config/environment.fixture"
cat >"$environment_file" <<'ENV'
export OPENAI_API_KEY = "from-file"
ANTHROPIC_API_KEY=other-file
ENV
runtime=$(jq -c --arg path "$environment_file" '.backend.env_file=$path' <<<"$runtime")
sf_environment_load "$environment_file" OPENAI_API_KEY
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=from-file' ]]
[[ $runtime != *from-file* ]]

export OPENAI_API_KEY=''
sf_environment_load "$environment_file" OPENAI_API_KEY
[[ ${(j: :)SF_ENVIRONMENT_VALUES} == 'OPENAI_API_KEY=' ]]
unset OPENAI_API_KEY

print -r -- 'invalid line' >>"$environment_file"
if sf_environment_load "$environment_file" OPENAI_API_KEY; then
  fail 'invalid env file tail was accepted'
fi
