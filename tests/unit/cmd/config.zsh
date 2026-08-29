#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp config-command

typeset config_dir="$tmp/config"
mkdir -p "$config_dir"
cat >"$config_dir/config.jsonc" <<'EOF'
{
  "default_profile": "agent",
  "backends": {"work": {"adapter": "openai", "api_key_env": "OPENAI_API_KEY"}},
  "profiles": {
    "agent": {
      "extend": "default",
      "backend": "work",
      "request": {"model": "gpt-4o"}
    }
  }
}
EOF

typeset entry="$ROOT/bin/shellfish"
typeset report

# `shellfish config` reports the runtime a new session would store, plus the
# theme palettes and TUI limits a session does not store.
report=$(zsh -f "$entry" config --config "$config_dir/config.jsonc") ||
  fail 'config report failed'
assert_equal gpt-4o "$(jq -r '.profile.request.model' <<<"$report")" 'config reports the model'
[[ $(jq -r '.backend.command' <<<"$report") == */openai/run ]] || fail 'config reports the backend command'
assert_equal auto "$(jq -r '.theme.mode' <<<"$report")" 'config reports the theme mode'
assert_equal light "$(jq -r '.theme.light.name' <<<"$report")" 'config names the light theme'
assert_equal true "$(jq -r '.theme.dark.palette | has("error")' <<<"$report")" \
  'config hydrates theme palettes'
assert_equal 2 "$(jq -r '.tui.preview_lines_context' <<<"$report")" 'config reports TUI limits'

# Runtime overrides reach the report the same way they reach a new session.
report=$(zsh -f "$entry" config --config "$config_dir/config.jsonc" -m claude-3) || \
  fail 'config report with override failed'
assert_equal claude-3 "$(jq -r '.profile.request.model' <<<"$report")" 'config applies --model'

# A stored session supplies its runtime; themes and limits come from current config.
jq -cn '{
  type:"session",format_version:1,cwd:"/tmp",created:"2026-08-18T00:00:00Z",
  profile:{request:{model:"stored-model"}},
  backend:{name:"test",command:"/bin/true",endpoint:"https://example.invalid",
    api_key_env:"",env_file:"",insecure_tls:false,http_timeout:30,http_stall:10},
  harness:{sandbox_read_paths:[],sandbox_write_paths:[],
    fence:"",tools:[],sandbox:false,
    max_requests_per_turn:8,max_tool_calls_per_request:16,max_capture_bytes:65536}
}' >"$tmp/stored.jsonl"
echo '{"type":"message","role":"user","content":[{"type":"text","text":"hi"}]}' >>"$tmp/stored.jsonl"
report=$(zsh -f "$entry" config --config "$config_dir/config.jsonc" --session "$tmp/stored.jsonl") || \
  fail 'config session report failed'
assert_equal auto "$(jq -r '.theme.mode' <<<"$report")" 'config --session reports the current theme mode'
assert_equal 2 "$(jq -r '.tui.preview_lines_context' <<<"$report")" \
  'config --session reports current TUI limits'
mkdir "$tmp/extra"
if zsh -f "$entry" config --config "$config_dir/config.jsonc" \
    --session "$tmp/stored.jsonl" --sandbox-write "$tmp/extra" >/dev/null 2>&1; then
  fail '--sandbox-write overrode an existing session'
fi

# --verbose lifts every preview limit without altering the stored runtime.
report=$(zsh -f "$entry" config --config "$config_dir/config.jsonc" --verbose) || \
  fail 'config verbose report failed'
assert_equal 'full full full full' \
  "$(jq -r '[.tui.preview_lines_reasoning, .tui.preview_lines_context,
    .tui.preview_lines_tool_call, .tui.preview_lines_tool_result] | join(" ")' <<<"$report")" \
  '--verbose lifts every preview limit'
report=$(zsh -f "$entry" config --config "$config_dir/config.jsonc" \
  --session "$tmp/stored.jsonl" --verbose) || fail 'config verbose session report failed'
assert_equal full "$(jq -r '.tui.preview_lines_context' <<<"$report")" \
  '--verbose reaches a stored session'
assert_equal stored-model "$(jq -r '.profile.request.model' <<<"$report")" \
  '--verbose leaves the stored runtime alone'

# --continue and --resume are rejected.
integer exit_code=0
zsh -f "$entry" config --continue >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail '--continue not rejected for config'
exit_code=0
zsh -f "$entry" config --resume >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail '--resume not rejected for config'
exit_code=0
zsh -f "$entry" config --clear >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail '--clear not rejected for config'
exit_code=0
zsh -f "$entry" config --new >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail '--new not rejected for config'

# Runtime overrides cannot be used with an existing session.
exit_code=0
zsh -f "$entry" config --config "$config_dir/config.jsonc" --session "$tmp/stored.jsonl" -m other \
  >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'overrides not rejected with --session'

# A profile that cannot resolve fails the same way starting a session would.
exit_code=0
zsh -f "$entry" config --config "$config_dir/config.jsonc" -p default >/dev/null 2>&1 || exit_code=$?
(( exit_code == 1 )) || fail 'unresolvable profile did not fail'

print -r -- 'ok'
