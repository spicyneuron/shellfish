#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source runtime/main.zsh session/main.zsh

typeset config runtime tool_name jsonc
sf_test_tmp runtime
mkdir -p "$tmp/config" "$tmp/home"
export HOME="${tmp:A}/home"
unset XDG_CONFIG_HOME
config="$tmp/config/shellfish.jsonc"

cat >"$config" <<'JSON'
{
  "default_profile": "work",
  "theme_mode": "light",
  "theme_light": "light",
  "theme_dark": "dark",
  "backends": {
    "custom": {"adapter": "openai"}
  },
  "profiles": {
    "work": {
      "backend": "custom",
      "request": {"model": "configured", "temperature": 0.2}
    }
  },
  "themes": {
    "light": {"text": "#123456"}
  }
}
JSON

cat >"$tmp/config/string-values.jsonc" <<'JSON'
{
  // line comment
  "line": "https://example.invalid/a//b",
  /* block comment */
  "block": "literal /* comment */",
  "quote": "escaped quote: \"// still text\" and \"/* too */\"",
  // another comment
  "path": "C:\\Users\\shellfish\\shellfish.jsonc"
}
JSON
jsonc=$(sf_runtime_read_jsonc "$tmp/config/string-values.jsonc")
jq -e '. == {
  line:"https://example.invalid/a//b",
  block:"literal /* comment */",
  quote:"escaped quote: \"// still text\" and \"/* too */\"",
  path:"C:\\Users\\shellfish\\shellfish.jsonc"
}' <<<"$jsonc" >/dev/null

sf_runtime_resolve_from_config "$config" '' 'cli-model' '{"temperature":0.7,"seed":4}'
runtime=$REPLY
jq -e --arg command "$ROOT/default/backends/openai/run" '
  .profile.request == {model:"cli-model",temperature:0.7,seed:4} and
  .backend.name == "custom" and
  .backend.command == $command and
  (.backend.env_file | endswith("/config/.env")) and
  .backend.endpoint == "https://api.openai.com/v1/chat/completions" and
  .backend.api_key_env == "OPENAI_API_KEY" and
  .harness == {
    sandbox_read_paths:[],sandbox_write_paths:[],
    fence:"",tools:[],sandbox:true,
    max_requests_per_turn:100,max_tool_calls_per_request:25,
    max_capture_bytes:32768
  }
' <<<"$runtime" >/dev/null
jq -e '
  .theme_mode == "light" and .theme_light == "light" and
  .themes.light.text == "#123456" and
  .tui.preview_lines_context == 2
' <<<"$SF_PRESENTATION" >/dev/null

print -r -- '{}' >"$tmp/config/empty.jsonc"
sf_runtime_resolve_from_config "$tmp/config/empty.jsonc" '' 'default-model' '{}' \
  "$ROOT/tests/fixtures/backend"
jq -e --arg root "$ROOT/default/hooks/session_start" \
  --arg tools "$ROOT/default/tools" '
  .harness.session_start == [
    ($root + "/add_environment"),
    ($root + "/add_command_availability"),
    ($root + "/add_project_instructions")
  ] and
  (.harness.tools | map(.name)) ==
    ["read_file", "edit_file", "write_file", "search_web", "fetch_url", "shell"] and
  (.harness.tools[] | select(.name == "search_web") |
    .command == ($tools + "/search_web/run") and
    .settings.network.allowedDomains == ["mcp.exa.ai"]) and
  (.harness.tools[] | select(.name == "fetch_url") |
    .command == ($tools + "/fetch_url/run") and
    .settings.network.allowedDomains == ["r.jina.ai"])
' <<<"$REPLY" >/dev/null

# Runtime resolution gives new and existing sessions the same boundary.
sf_runtime_resolve '' "$config" '' 'boundary-model' '{}' '' 1
jq -e '.profile.request.model == "boundary-model"' <<<"$REPLY" >/dev/null
jq -e '.theme_mode == "light" and .themes.light.text == "#123456"' \
  <<<"$SF_PRESENTATION" >/dev/null

typeset session="$tmp/session.jsonl"
jq -cn --argjson runtime "$runtime" '
  {type:"session",format_version:1,cwd:"/",created:"2026-08-18T00:00:00Z"} + $runtime
' >"$session"
sf_runtime_resolve "$session" "$config" '' '' '{}' '' 0
assert_equal "$runtime" "$REPLY" 'runtime resolution reads the frozen runtime'
jq -e '.theme_mode == "light" and .themes.light.text == "#123456"' \
  <<<"$SF_PRESENTATION" >/dev/null
integer resolve_status=0
sf_runtime_resolve "$session" "$config" '' changed '{}' '' 1 || resolve_status=$?
(( resolve_status == 2 ))
[[ $SF_RUNTIME_ERROR == 'runtime overrides cannot be used with an existing session' ]]

# Hooked runtimes require a persistent state base before a session starts.
integer had_home=${+HOME} had_state_home=${+XDG_STATE_HOME}
typeset saved_home=${HOME-} saved_state_home=${XDG_STATE_HOME-}
typeset hooked_session="$tmp/hooked.jsonl"
jq -cn --argjson runtime "$runtime" '
  {type:"session",format_version:1,cwd:"/",
   created:"2026-08-18T00:00:00Z"} +
  ($runtime | .harness.stop=["/bin/hook"])
' >"$hooked_session"
unset HOME XDG_STATE_HOME
if sf_runtime_resolve "$hooked_session" "$config" '' '' '{}' '' 0; then
  fail 'hooked runtime resolved without a persistent state base'
fi
[[ $SF_RUNTIME_ERROR == 'HOME or XDG_STATE_HOME is required for persistent hook data' ]]
if (( had_home )); then export HOME=$saved_home; else unset HOME; fi
if (( had_state_home )); then export XDG_STATE_HOME=$saved_state_home
else unset XDG_STATE_HOME; fi

# Reopening reads only current presentation keys. Unrelated invalid profile
# data does not prevent a stored runtime from being presented.
cat >"$tmp/config/presentation.jsonc" <<'JSON'
{
  "profiles": "ignored while reopening",
  "theme_mode": "light",
  "theme_light": "light",
  "theme_dark": "dark",
  "themes": {"light": {"text": "#abcdef"}},
  "tui": {"preview_lines_context": 9}
}
JSON
sf_runtime_restore_presentation "$tmp/config/presentation.jsonc"
jq -e '
  .theme_mode == "light" and .themes.light.text == "#abcdef" and
  .tui.preview_lines_context == 9
' <<<"$SF_PRESENTATION" >/dev/null

print -r -- '{"theme_light":"missing"}' >"$tmp/config/missing-theme.jsonc"
if sf_runtime_restore_presentation "$tmp/config/missing-theme.jsonc"; then
  fail 'missing current theme was accepted'
fi
[[ $SF_RUNTIME_ERROR == 'unknown theme: missing' ]]
if sf_runtime_resolve_from_config "$tmp/config/missing-theme.jsonc" '' 'model' '{}' \
    "$ROOT/tests/fixtures/backend"; then
  fail 'prospective runtime accepted a missing theme'
fi
[[ $SF_RUNTIME_ERROR == 'unknown theme: missing' ]]

sf_runtime_resolve_from_config "$config" work '' '{}' "$ROOT/tests/fixtures/backend"
jq -e '
  .backend.endpoint == "https://example.invalid/test" and
  (.backend.command | endswith("/tests/fixtures/backend/run"))
' <<<"$REPLY" >/dev/null

# Relative external backend paths remain relative to the working directory.
mkdir -p "$tmp/fixtures"
ln -s "$ROOT/tests/fixtures/backend" "$tmp/fixtures/backend"
(
  cd "$tmp"
  sf_runtime_resolve_from_config "$config" work '' '{}' fixtures/backend
  jq -e --arg command "$ROOT/tests/fixtures/backend/run" \
    '.backend.command == $command' <<<"$REPLY" >/dev/null
)

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

mkdir "$tmp/empty-config"
(
  export XDG_CONFIG_HOME="$tmp/empty-config"
  sf_runtime_resolve_from_config '' '' test-model '{}' "$ROOT/tests/fixtures/backend"
  jq -e '
    .profile.request.model == "test-model" and
    (.backend.command | endswith("/tests/fixtures/backend/run"))
  ' <<<"$REPLY" >/dev/null
)

if sf_runtime_resolve_from_config "$config" work '' '{}' "$tmp/not-a-backend"; then
  fail 'invalid CLI backend path was accepted'
fi

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

cat >"$tmp/config/unterminated.jsonc" <<'JSON'
{"profiles": { /* unfinished
JSON
if sf_runtime_resolve_from_config "$tmp/config/unterminated.jsonc" '' '' '{}'; then
  fail 'unterminated JSONC comment was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid config: '*'unterminated.jsonc: unterminated block comment'* ]]

cat >"$tmp/config/invalid-field.jsonc" <<'JSON'
{"profiles":{"work":{"legacy_backend":"test"}}}
JSON
if sf_runtime_resolve_from_config "$tmp/config/invalid-field.jsonc" '' '' '{}'; then
  fail 'unknown config field was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid config at $["profiles"]["work"]["legacy_backend"]: unknown field'* ]]

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

cat >"$tmp/config/invalid-presentation.jsonc" <<'JSON'
{"tui":{"preview_lines_context":-1}}
JSON
if sf_runtime_restore_presentation "$tmp/config/invalid-presentation.jsonc"; then
  fail 'invalid presentation field was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid config at $["tui"]["preview_lines_context"]: must be full or a non-negative integer'* ]]

# Hook references preserve event and configured order, prefer the config
# directory, and freeze as absolute executables inside the harness.
mkdir -p "$tmp/config/hooks/user_prompt_submit"
print -r -- '#!/bin/sh' >"$tmp/config/hooks/user_prompt_submit/help"
chmod +x "$tmp/config/hooks/user_prompt_submit/help"
print -r -- '#!/bin/sh' >"$tmp/config/hooks/user_prompt_submit/shell"
chmod +x "$tmp/config/hooks/user_prompt_submit/shell"
mkdir -p "$tmp/config/hooks/stop"
print -r -- '#!/bin/sh' >"$tmp/config/hooks/stop/gate"
chmod +x "$tmp/config/hooks/stop/gate"
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
    ($base + "/user_prompt_submit/help"),
    ($base + "/user_prompt_submit/shell")
  ] and .harness.stop == [($base + "/stop/gate")]
' <<<"$REPLY" >/dev/null

chmod -x "$tmp/config/hooks/user_prompt_submit/help"
if sf_runtime_resolve_from_config "$tmp/config/hooked.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"; then
  fail 'non-executable hook was accepted'
fi
[[ $SF_RUNTIME_ERROR == 'user_prompt_submit hook is not executable: help' ]]
chmod +x "$tmp/config/hooks/user_prompt_submit/help"

cat >"$tmp/config/malformed-hooks.jsonc" <<'JSON'
{"harnesses":{"bad":{"stop":"gate"}}}
JSON
if sf_runtime_resolve_from_config "$tmp/config/malformed-hooks.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"; then
  fail 'non-array hook list was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid config at $["harnesses"]["bad"]["stop"]: must be references'* ]]

cat >"$tmp/config/unknown-hook-event.jsonc" <<'JSON'
{"harnesses":{"bad":{"before_prompt":[]}}}
JSON
if sf_runtime_resolve_from_config "$tmp/config/unknown-hook-event.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"; then
  fail 'unknown hook event was accepted'
fi
[[ $SF_RUNTIME_ERROR == *'invalid config at $["harnesses"]["bad"]["before_prompt"]: unknown field'* ]]

# System references resolve to one durable record and never enter the header.
mkdir -p "$tmp/config/prompts/system"
print -r -- 'first' >"$tmp/config/prompts/system/first.md"
print -r -- 'second' >"$tmp/config/prompts/second.md"
cat >"$tmp/config/system.jsonc" <<'JSON'
{
  "profiles":{"default":{"harness":"system","request":{"model":"m"}}},
  "harnesses":{"system":{"system":["system/first.md","second.md"]}}
}
JSON
sf_runtime_resolve_from_config "$tmp/config/system.jsonc" '' '' '{}' \
  "$ROOT/tests/fixtures/backend"
jq -e '.harness | has("system") | not' <<<"$REPLY" >/dev/null
jq -e '. == {type:"system",content:"first\n\nsecond"}' \
  <<<"$SF_RUNTIME_SYSTEM_RECORD" >/dev/null
rm "$tmp/config/prompts/second.md"
if sf_runtime_resolve_from_config "$tmp/config/system.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"; then
  fail 'missing prompt file was accepted'
fi

# The template's readonly harness resolves its bundled nested prompt.
sf_runtime_read_jsonc "$ROOT/template/shellfish.jsonc" |
  jq -c '.profiles.default.harness = "readonly"' >"$tmp/config/readonly.jsonc"
sf_runtime_resolve_from_config "$tmp/config/readonly.jsonc" '' 'm' '{}' \
  "$ROOT/tests/fixtures/backend"
jq -e --arg content "$(<"$ROOT/default/prompts/system/readonly.md")" \
  '. == {type:"system",content:$content}' <<<"$SF_RUNTIME_SYSTEM_RECORD" >/dev/null

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
[[ $SF_RUNTIME_ERROR == 'stop hook is not executable: missing' ]]

# A configured hook wins over a bundled hook with the same name. Removing it
# exercises bundled fallback. Use an isolated root so this adds no production
# hook.
mkdir -p "$tmp/root/default/hooks/stop"
ln -s "$ROOT/lib" "$tmp/root/lib"
ln -s "$ROOT/default/shellfish.jsonc" "$tmp/root/default/shellfish.jsonc"
print -r -- '#!/bin/sh' >"$tmp/root/default/hooks/stop/bundled"
chmod +x "$tmp/root/default/hooks/stop/bundled"
mkdir -p "$tmp/hooks/stop"
print -r -- '#!/bin/sh' >"$tmp/hooks/stop/bundled"
chmod +x "$tmp/hooks/stop/bundled"
cat >"$tmp/bundled.jsonc" <<'JSON'
{
  "profiles":{"default":{"harness":"fallback","request":{"model":"m"}}},
  "harnesses":{"fallback":{"stop":["bundled"]}}
}
JSON
SF_ROOT="$tmp/root"
sf_runtime_resolve_from_config "$tmp/bundled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg path "${tmp:A}/hooks/stop/bundled" \
  '.harness.stop == [$path]' <<<"$REPLY" >/dev/null
rm -f -- "$tmp/hooks/stop/bundled"
sf_runtime_resolve_from_config "$tmp/bundled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e --arg path "${tmp:A}/root/default/hooks/stop/bundled" \
  '.harness.stop == [$path]' <<<"$REPLY" >/dev/null
SF_ROOT=$ROOT

# Tool references freeze as executable paths, settings, and manifests in configured order.
mkdir -p "$tmp/config/tools"
for tool_name in alpha beta gamma delta epsilon; do
  mkdir "$tmp/config/tools/$tool_name"
  print -r -- '#!/bin/sh' >"$tmp/config/tools/$tool_name/run"
  chmod +x "$tmp/config/tools/$tool_name/run"
  jq -n --arg description "$tool_name tool" \
    '{description:$description,input_schema:{type:"object"},sandbox:false}' \
    >"$tmp/config/tools/$tool_name/tool.json"
done
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
  all(.harness.tools[]; .settings == null and (has("describe") | not)) and
  .harness.tools[0].manifest.description == "beta tool"
' <<<"$REPLY" >/dev/null

# A sandboxed tool resolves only once its package carries fence settings.
jq -n '{description:"sandboxed",input_schema:{type:"object"},sandbox:true}' \
  >"$tmp/config/tools/alpha/tool.json"
if sf_runtime_resolve_from_config "$tmp/config/tooled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"; then
  fail 'sandboxed tool without fence settings was accepted'
fi
[[ $SF_RUNTIME_ERROR == *"cannot read tool sandbox settings: ${tmp:A}/config/tools/alpha/fence.jsonc"* ]]
print -r -- '{}' >"$tmp/config/tools/alpha/fence.jsonc"
sf_runtime_resolve_from_config "$tmp/config/tooled.jsonc" '' '' '{}' "$ROOT/tests/fixtures/backend"
jq -e '(.harness.tools | map(.name)) == ["beta", "alpha", "gamma", "delta", "epsilon"] and
  .harness.tools[1].manifest.sandbox == true' <<<"$REPLY" >/dev/null

# An unsandboxed harness resolves sandboxed tool settings without requiring fence.
jq '.harnesses.tooled.sandbox=false' "$tmp/config/tooled.jsonc" \
  >"$tmp/config/unsandboxed-tools.jsonc"
(
  unset 'commands[fence]'
  sf_runtime_resolve_from_config "$tmp/config/unsandboxed-tools.jsonc" '' '' '{}' \
    "$ROOT/tests/fixtures/backend"
  jq -e '.harness.sandbox == false and .harness.fence == ""' <<<"$REPLY" >/dev/null
)

# Credentials are selected into memory, removed from the inherited environment,
# and never added to the durable runtime.
export OPENAI_API_KEY='from-environment'
export ANTHROPIC_API_KEY='must-not-leak'
sf_runtime_resolve_from_config "$config" work '' '{}'
runtime=$REPLY
sf_runtime_resolve_api_key "$runtime"
[[ $REPLY == from-environment && $reply[1] == OPENAI_API_KEY ]]
(( ! ${+OPENAI_API_KEY} && ! ${+ANTHROPIC_API_KEY} ))
[[ $runtime != *from-environment* ]]

export SHELLFISH_API_KEY='' OPENAI_API_KEY='provider-value'
sf_runtime_resolve_api_key "$(jq -c '.backend.env_file=""' <<<"$runtime")"
[[ -z $REPLY && $reply[1] == SHELLFISH_API_KEY ]]
(( ! ${+SHELLFISH_API_KEY} && ! ${+OPENAI_API_KEY} ))

# The resolved .env path is asserted above. Use a non-secret fixture name here
# because the bundled tool sandbox intentionally denies all .env access.
typeset credential_file="$tmp/config/credentials.fixture"
typeset credential_runtime=$(jq -c --arg env_file "$credential_file" \
  '.backend.env_file=$env_file' <<<"$runtime")
cat >"$credential_file" <<'ENV'
export OPENAI_API_KEY = "from-file"
SHELLFISH_API_KEY=global-file
ENV
sf_runtime_resolve_api_key "$credential_runtime"
[[ $REPLY == global-file && $reply[1] == SHELLFISH_API_KEY ]]
[[ $runtime != *from-file* ]]

print -r -- 'invalid line' >>"$credential_file"
if sf_runtime_resolve_api_key "$credential_runtime"; then
  fail 'invalid env file tail was accepted'
fi
