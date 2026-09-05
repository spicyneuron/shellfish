#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp config-command

typeset config_dir="$tmp/config"
mkdir -p "$config_dir"
cat >"$config_dir/shellfish.jsonc" <<'EOF'
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

zmodload zsh/stat
file_mode() {
  local -a stat_result
  zstat -A stat_result +mode -- "$1" || return
  printf '%03o' $(( stat_result[1] & 8#777 ))
}

# Config initialization.
typeset init_home="$tmp/init-home"
typeset init_config="$init_home/config/shellfish/shellfish.jsonc"
(
  umask 000
  HOME="$init_home" XDG_CONFIG_HOME="$init_home/config" \
    zsh -f "$entry" config --init >/dev/null
) || fail 'config init failed'
[[ -f $init_config ]] || fail 'config init did not create the default path'
cmp -s "$ROOT/template/shellfish.jsonc" "$init_config" || fail 'config init did not copy the template'
typeset init_dir=${init_config:h}
cmp -s "$ROOT/template/example.env" "$init_dir/example.env" || \
  fail 'config init did not copy the environment example'
assert_equal 700 "$(file_mode "$init_dir")" 'config init did not protect the config directory'
assert_equal 600 "$(file_mode "$init_config")" 'config init did not protect the config file'
assert_equal 600 "$(file_mode "$init_dir/example.env")" \
  'config init did not protect the environment example'
for component in hooks backends tools skills; do
  [[ -d $init_dir/$component ]] || fail "config init did not create $component directory"
  assert_equal 700 "$(file_mode "$init_dir/$component")" \
    "config init did not protect the $component directory"
done
grep -qxF 'ANTHROPIC_API_KEY=' "$init_dir/example.env" || \
  fail 'environment example omitted the Anthropic credential'
grep -qxF 'OPENAI_API_KEY=' "$init_dir/example.env" || \
  fail 'environment example omitted the OpenAI credential'
grep -qxF 'OPENROUTER_API_KEY=' "$init_dir/example.env" || \
  fail 'environment example omitted the OpenRouter credential'
if HOME="$init_home" XDG_CONFIG_HOME="$init_home/config" \
  zsh -f "$entry" config --init >/dev/null 2>&1; then
  fail 'config init overwrote an existing config'
fi
typeset custom_config="$tmp/custom/shellfish.jsonc"
mkdir -p "${custom_config:h}/system"
print -r -- 'KEEP=1' >"${custom_config:h}/example.env"
print -r -- 'custom' >"${custom_config:h}/system/custom.md"
chmod 750 "${custom_config:h}/system"
chmod 640 "${custom_config:h}/example.env"
zsh -f "$entry" config --init --config "$custom_config" >/dev/null || \
  fail 'config init with an explicit path failed'
cmp -s "$ROOT/template/shellfish.jsonc" "$custom_config" || \
  fail 'config init did not use the explicit path'
grep -qxF 'KEEP=1' "${custom_config:h}/example.env" || \
  fail 'config init overwrote an existing environment example'
grep -qxF 'custom' "${custom_config:h}/system/custom.md" || \
  fail 'config init overwrote an existing component'
assert_equal 640 "$(file_mode "${custom_config:h}/example.env")" \
  'config init changed permissions on an existing environment example'
assert_equal 750 "$(file_mode "${custom_config:h}/system")" \
  'config init changed permissions on an existing component directory'

# Automatic sandbox grants.
typeset detector_bin="$tmp/detectors"
typeset detector_root="$tmp/detected"
typeset git_root="$detector_root/git-config"
mkdir -p "$detector_bin" "$detector_root"/{go-mod,uv,python,npm,pnpm,rust,registry,git} \
  "$git_root"
touch "$detector_root"/{.package-cache,.package-cache-mutate,.global-cache}
touch "$git_root"/{attributes,ignore}
print -r -- '[user]' '  name = Test' >"$git_root/include.conf"
print -r -- '[include]' "  path = $git_root/include.conf" >"$git_root/config"
detector_root=${detector_root:A}
git_root=${git_root:A}
typeset go_cache="$init_home/Library/Caches/go-build"
mkdir -p "$go_cache"
cat >"$detector_bin/go" <<EOF
#!/bin/sh
printf '%s\n' '{"GOCACHE":"$go_cache","GOMODCACHE":"$detector_root/go-mod"}'
EOF
cat >"$detector_bin/uv" <<EOF
#!/bin/sh
printf '%s\n' '$detector_root/uv'
EOF
cat >"$detector_bin/python3" <<EOF
#!/bin/sh
printf '%s\n' '$detector_root/python'
EOF
cat >"$detector_bin/npm" <<EOF
#!/bin/sh
printf '%s\n' '$detector_root/npm'
EOF
cat >"$detector_bin/pnpm" <<EOF
#!/bin/sh
printf '%s\n' '$detector_root/pnpm'
EOF
cat >"$detector_bin/rustc" <<EOF
#!/bin/sh
printf '%s\n' '$detector_root/rust'
EOF
cat >"$detector_bin/cargo" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$detector_bin/git" <<EOF
#!/bin/sh
last=''
for arg in "\$@"; do last=\$arg; done
if [ "\$1" = var ] && [ "\$2" = GIT_CONFIG_GLOBAL ]; then
  printf '%s\n' '$git_root/config'
elif [ "\$1" = var ] && [ "\$2" = GIT_ATTR_GLOBAL ]; then
  printf '%s\n' '$git_root/attributes'
elif [ "\$1" = config ] && [ "\$last" = core.excludesFile ]; then
  printf '%s\n' '$git_root/ignore'
elif [ "\$1" = config ]; then
  printf 'file:%s\0user.name\nTest\0file:%s\0user.email\ntest@example.com\0' \
    '$git_root/config' '$git_root/include.conf'
else
  exit 1
fi
EOF
chmod +x "$detector_bin"/*
typeset auto_config="$tmp/auto/shellfish.jsonc"
PATH="$detector_bin:$PATH" HOME="$init_home" CARGO_HOME="$detector_root" \
  zsh -f "$entry" config --init --sandbox-auto --config "$auto_config" >/dev/null || \
  fail 'automatic sandbox config init failed'
jq -e --arg go_cache "~/Library/Caches/go-build" --arg go_mod "$detector_root/go-mod" \
  --arg uv "$detector_root/uv" --arg python "$detector_root/python" \
  --arg npm "$detector_root/npm" --arg pnpm "$detector_root/pnpm" \
  --arg rust "$detector_root/rust" --arg registry "$detector_root/registry" \
  --arg git "$detector_root/git" --arg package_cache "$detector_root/.package-cache" \
  --arg package_mutate "$detector_root/.package-cache-mutate" \
  --arg global_cache "$detector_root/.global-cache" --arg git_root "$git_root" '
    (.harnesses.default.sandbox_read_paths | sort) ==
      ([$rust,($git_root + "/config"),($git_root + "/attributes"),
        ($git_root + "/ignore"),($git_root + "/include.conf")] | sort) and
    (.harnesses.default.sandbox_write_paths | sort) ==
      ([$go_cache,$go_mod,$uv,$python,$npm,$pnpm,$registry,$git,
        $package_cache,$package_mutate,$global_cache] | sort)
  ' < <(source "$ROOT/libexec/config/runtime.zsh"; sf_runtime_read_jsonc "$auto_config") >/dev/null || \
  fail 'config init did not write automatic sandbox grants'
grep -q '^// Shellfish config$' "$auto_config" || fail 'config init did not preserve template comments'

mkdir "$tmp/explicit"
report=$(PATH="$detector_bin:$PATH" HOME="$init_home" CARGO_HOME="$detector_root" \
  zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" --sandbox-auto \
    --sandbox-read "$tmp/explicit") || fail 'automatic sandbox config report failed'
jq -e --arg explicit "${tmp:A}/explicit" --arg rust "$detector_root/rust" \
  --arg go_mod "$detector_root/go-mod" '
    (.harness.sandbox_read_paths | index($explicit)) != null and
    (.harness.sandbox_read_paths | index($rust)) != null and
    (.harness.sandbox_read_paths | index($explicit) < index($rust)) and
    (.harness.sandbox_write_paths | index($go_mod)) != null
  ' <<<"$report" >/dev/null || fail 'automatic and explicit sandbox grants were not additive'

typeset empty_bin="$tmp/empty-bin"
typeset zsh_bin="${commands[zsh]}"
mkdir "$empty_bin"
for utility in awk cp fence jq ln mkdir mktemp rm zsh; do
  ln -s "${commands[$utility]}" "$empty_bin/$utility"
done
mkdir "$tmp/empty-home"
report=$(PATH="$empty_bin" HOME="$tmp/empty-home" XDG_CONFIG_HOME='' \
  "$zsh_bin" -f "$entry" config \
  --config "$config_dir/shellfish.jsonc" --sandbox-auto) || fail 'empty sandbox detection failed'
jq -e '.harness.sandbox_read_paths == [] and .harness.sandbox_write_paths == []' \
  <<<"$report" >/dev/null || fail "empty sandbox detection added grants: \
$(jq -c '.harness | {sandbox_read_paths,sandbox_write_paths}' <<<"$report")"
typeset empty_auto_config="$tmp/empty-auto/shellfish.jsonc"
PATH="$empty_bin" HOME="$tmp/empty-home" XDG_CONFIG_HOME='' \
  "$zsh_bin" -f "$entry" config --init --sandbox-auto --config "$empty_auto_config" \
  >/dev/null || fail 'empty automatic sandbox config init failed'
if grep -Eq '"sandbox_(read|write)_paths": \[\]' "$empty_auto_config"; then
  fail 'config init collapsed an empty sandbox array'
fi
grep -qxF '        // Paths outside the project that sandboxed tools may read' \
  "$empty_auto_config" || \
  fail 'empty sandbox read config omitted path guidance'
grep -qxF '        // Paths outside the project that sandboxed tools may read and write' \
  "$empty_auto_config" || fail 'empty sandbox write config omitted path guidance'
jq -e '.harnesses.default.sandbox_read_paths == [] and
  .harnesses.default.sandbox_write_paths == []' \
  < <(source "$ROOT/libexec/config/runtime.zsh"; sf_runtime_read_jsonc "$empty_auto_config") \
  >/dev/null || fail 'empty automatic sandbox config is invalid'

# `shellfish config` reports the runtime a new session would store, plus the
# theme palettes and TUI limits a session does not store.
report=$(zsh -f "$entry" config --config "$config_dir/shellfish.jsonc") ||
  fail 'config report failed'
assert_equal gpt-4o "$(jq -r '.profile.request.model' <<<"$report")" 'config reports the model'
[[ $(jq -r '.backend.command' <<<"$report") == */openai/run ]] || fail 'config reports the backend command'
assert_equal auto "$(jq -r '.theme.mode' <<<"$report")" 'config reports the theme mode'
assert_equal light "$(jq -r '.theme.light.name' <<<"$report")" 'config names the light theme'
assert_equal true "$(jq -r '.theme.dark.palette | has("error")' <<<"$report")" \
  'config hydrates theme palettes'
assert_equal 2 "$(jq -r '.tui.preview_lines_context' <<<"$report")" 'config reports TUI limits'

# Runtime overrides reach the report the same way they reach a new session.
report=$(zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" -m claude-3) || \
  fail 'config report with override failed'
assert_equal claude-3 "$(jq -r '.profile.request.model' <<<"$report")" 'config applies --model'

# A stored session supplies its runtime. Themes and limits come from current config.
jq -cn '{
  type:"session",format_version:1,cwd:"/tmp",created:"2026-08-18T00:00:00Z",
  profile:{request:{model:"stored-model"},system:[]},
  backend:{name:"test",command:"/bin/true",endpoint:"https://example.invalid",
    api_key_env:"",env_file:"",insecure_tls:false,http_timeout:30,http_stall:10},
  harness:{sandbox_read_paths:[],sandbox_write_paths:[],
    fence:"",tools:[],sandbox:false,
    max_requests_per_turn:8,max_tool_calls_per_request:16,max_capture_bytes:65536}
}' >"$tmp/stored.jsonl"
echo '{"type":"message","role":"user","content":[{"type":"text","text":"hi"}]}' >>"$tmp/stored.jsonl"
report=$(zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" --session "$tmp/stored.jsonl") || \
  fail 'config session report failed'
assert_equal auto "$(jq -r '.theme.mode' <<<"$report")" 'config --session reports the current theme mode'
assert_equal 2 "$(jq -r '.tui.preview_lines_context' <<<"$report")" \
  'config --session reports current TUI limits'
mkdir "$tmp/extra"
if zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" \
    --session "$tmp/stored.jsonl" --sandbox-write "$tmp/extra" >/dev/null 2>&1; then
  fail '--sandbox-write overrode an existing session'
fi

# --verbose lifts every preview limit without altering the stored runtime.
report=$(zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" --verbose) || \
  fail 'config verbose report failed'
assert_equal 'full full full full' \
  "$(jq -r '[.tui.preview_lines_reasoning, .tui.preview_lines_context,
    .tui.preview_lines_tool_call, .tui.preview_lines_tool_result] | join(" ")' <<<"$report")" \
  '--verbose lifts every preview limit'
report=$(zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" \
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
zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" --session "$tmp/stored.jsonl" -m other \
  >/dev/null 2>&1 || exit_code=$?
(( exit_code == 2 )) || fail 'overrides not rejected with --session'

# A profile that cannot resolve fails the same way starting a session would.
exit_code=0
zsh -f "$entry" config --config "$config_dir/shellfish.jsonc" -p default >/dev/null 2>&1 || exit_code=$?
(( exit_code == 1 )) || fail 'unresolvable profile did not fail'

print -r -- 'ok'
