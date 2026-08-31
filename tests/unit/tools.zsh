#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_source session/main.zsh runtime/main.zsh tools.zsh

sf_test_tmp tools
typeset session="$tmp/session.jsonl"
typeset tool_dir="$ROOT/default/tools/shell"
sf_test_runtime
sf_test_session "$session"
SF_SESSION_PATH=$session
typeset stored_runtime=$(head -n 1 "$session" | jq -c 'del(.type,.format_version,.cwd,.created)')
typeset stored_cwd=$(jq -r '.cwd' "$session")
typeset tool_tools tool_schema tool_cwd=$stored_cwd tool_max_capture tool_sandbox tool_fence
typeset tool_read_paths tool_write_paths tool_config_dir=''

load_tools() {
  local runtime=$1 permission_available=${2:-0}
  tool_tools=$(jq -c '.harness.tools' <<<$runtime)
  tool_max_capture=$(jq -r '.harness.max_capture_bytes' <<<$runtime)
  tool_sandbox=$(jq -r 'if .harness.sandbox then 1 else 0 end' <<<$runtime)
  tool_fence=$(jq -r '.harness.fence' <<<$runtime)
  tool_read_paths=$(jq -c '.harness.sandbox_read_paths' <<<$runtime)
  tool_write_paths=$(jq -c '.harness.sandbox_write_paths' <<<$runtime)
  sf_tools_load "$tool_tools" "$permission_available" "$tool_cwd" \
    "$tool_max_capture" "$tool_sandbox" "$tool_fence"
  tool_schema=$REPLY
}

sf_test_tool_execute() {
  sf_tool_execute "$1" "$2" "${3-}" "${4-}" "$tool_tools" "$tool_cwd" \
    "$tool_max_capture" "$tool_fence" "$tool_read_paths" "$tool_write_paths" "$tool_config_dir"
}

# The web fetch tool validates its input and sends only fixed Reader options to curl.
mkdir "$tmp/jina-bin"
cat >"$tmp/jina-bin/curl" <<'ZSH'
#!/usr/bin/env zsh
print -rl -- "$@" >"$JINA_TEST_ARGS"
print -r -- '# fetched markdown'
exit "${JINA_TEST_STATUS:-0}"
ZSH
chmod +x "$tmp/jina-bin/curl"
typeset jina_args="$tmp/jina.args" jina_output
jina_output=$(PATH="$tmp/jina-bin:$PATH" JINA_TEST_ARGS="$jina_args" \
  "$ROOT/default/tools/fetch_url/run" <<<'{"url":"https://example.com/docs?q=reader"}')
assert_equal '# fetched markdown' "$jina_output"
typeset -a expected_jina_args=(
  --disable --silent --show-error --fail-with-body --connect-timeout 10 --max-time 60
  --header 'X-Return-Format: markdown' --
  'https://r.jina.ai/https://example.com/docs?q=reader'
)
assert_equal "${(F)expected_jina_args}" "$(<"$jina_args")"
if PATH="$tmp/jina-bin:$PATH" JINA_TEST_ARGS="$jina_args" \
    "$ROOT/default/tools/fetch_url/run" <<<'{"url":"file:///etc/passwd"}' >/dev/null 2>&1; then
  fail 'fetch_url accepted a non-HTTP URL'
fi
if PATH="$tmp/jina-bin:$PATH" JINA_TEST_ARGS="$jina_args" \
    "$ROOT/default/tools/fetch_url/run" <<<'{"url":"https://example.com","extra":true}' >/dev/null 2>&1; then
  fail 'fetch_url accepted an unknown input field'
fi
if PATH="$tmp/jina-bin:$PATH" JINA_TEST_ARGS="$jina_args" JINA_TEST_STATUS=22 \
    "$ROOT/default/tools/fetch_url/run" <<<'{"url":"https://example.com"}' >/dev/null 2>&1; then
  fail 'fetch_url hid a curl failure'
fi
jq -e '
  .network.allowedDomains == ["r.jina.ai"] and
  .network.allowLocalBinding == false and
  .network.allowLocalOutbound == false and
  .filesystem.defaultDenyRead == true
' "$ROOT/default/tools/fetch_url/fence.jsonc" >/dev/null

# The web search tool makes one fixed anonymous MCP call and decodes its SSE result.
mkdir "$tmp/exa-bin"
cat >"$tmp/exa-bin/curl" <<'ZSH'
#!/usr/bin/env zsh
print -rl -- "$@" >"$EXA_TEST_ARGS"
if [[ -n ${EXA_TEST_RESPONSE-} ]]; then
  print -r -- "$EXA_TEST_RESPONSE"
else
  cat <<'EOF'
event: message
data: {"result":{"content":[{"type":"text","text":"# search result"}]},"jsonrpc":"2.0","id":1}
EOF
fi
exit "${EXA_TEST_STATUS:-0}"
ZSH
chmod +x "$tmp/exa-bin/curl"
typeset exa_args="$tmp/exa.args" exa_output
exa_output=$(PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" \
  "$ROOT/default/tools/search_web/run" \
  <<<'{"query":"current shellfish CLI documentation","num_results":3}')
assert_equal '# search result' "$exa_output"
typeset -a expected_exa_args=(
  --disable --silent --show-error --fail-with-body --connect-timeout 10 --max-time 60
  --request POST
  --header 'Content-Type: application/json'
  --header 'Accept: application/json, text/event-stream'
  --header 'MCP-Protocol-Version: 2025-06-18'
  --header 'x-exa-source: shellfish'
  --data-binary '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"web_search_exa","arguments":{"query":"current shellfish CLI documentation","numResults":3}}}'
  -- 'https://mcp.exa.ai/mcp?tools=web_search_exa'
)
assert_equal "${(F)expected_exa_args}" "$(<"$exa_args")"
if PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" \
    "$ROOT/default/tools/search_web/run" \
    <<<'{"query":"docs","num_results":1.5}' >/dev/null 2>&1; then
  fail 'search_web accepted a fractional result count'
fi
if PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" \
    "$ROOT/default/tools/search_web/run" \
    <<<'{"query":"docs","extra":true}' >/dev/null 2>&1; then
  fail 'search_web accepted an unknown input field'
fi
typeset exa_error='{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"rate limited"}}'
if PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" EXA_TEST_RESPONSE="$exa_error" \
    "$ROOT/default/tools/search_web/run" <<<'{"query":"docs"}' >/dev/null 2>&1; then
  fail 'search_web accepted an MCP error response'
fi
if PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" EXA_TEST_STATUS=22 \
    "$ROOT/default/tools/search_web/run" <<<'{"query":"docs"}' >/dev/null 2>&1; then
  fail 'search_web hid a curl failure'
fi
jq -e '
  .network.allowedDomains == ["mcp.exa.ai"] and
  .network.allowLocalBinding == false and
  .network.allowLocalOutbound == false and
  .filesystem.defaultDenyRead == true
' "$ROOT/default/tools/search_web/fence.jsonc" >/dev/null

# Tool execution preserves the caller's home in its otherwise clean environment.
load_tools "$stored_runtime"
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$HOME"' \
  '{id:"home_1",name:"shell",input:{command:$command}}')" 0
jq -e --arg home "$HOME" '.content == $home' <<<"$REPLY" >/dev/null
tool_config_dir="$tmp/custom-config"
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$SHELLFISH_CONFIG_DIR"' \
  '{id:"config_dir_1",name:"shell",input:{command:$command}}')" 0
jq -e --arg config "$tool_config_dir" '.content == $config' <<<"$REPLY" >/dev/null
tool_config_dir=''
typeset caller_home=$HOME
mkdir "$tmp/home"
export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/xdg"
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$XDG_CONFIG_HOME"' \
  '{id:"xdg_config_1",name:"shell",input:{command:$command}}')" 0
jq -e --arg config "$XDG_CONFIG_HOME" '.content == $config' <<<"$REPLY" >/dev/null
export HOME=$caller_home
unset XDG_CONFIG_HOME

# Capture preserves trailing newlines and retains only the configured byte tail.
sf_test_tool_execute "$(jq -cn --arg command "printf 'line\\n\\n'" \
  '{id:"capture_1",name:"shell",input:{command:$command}}')" 0
jq -e '.content == "line\n\n" and .sandboxed == false' \
  <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn \
  '{id:"capture_bypass",name:"shell",input:{command:"true",request_sandbox_bypass:true,
    sandbox_bypass_reason:"test"}}')" 0
jq -e '.exit_code == 0' <<<"$REPLY" >/dev/null
tool_max_capture=64
sf_test_tool_execute "$(jq -cn --arg command "printf '%070d' 0" \
  '{id:"capture_2",name:"shell",input:{command:$command}}')" 0
jq -e '(.content | length) == 64 and (.content | startswith("[output truncated]\n"))' \
  <<<"$REPLY" >/dev/null

# Timeout terminates the command and returns the canonical timeout result.
sf_test_tool_execute "$(jq -cn \
  '{id:"timeout_1",name:"shell",input:{command:"sleep 5",timeout:1}}')" 0
jq -e '.exit_code == 124 and (.content | contains("timed out after 1 seconds"))' \
  <<<"$REPLY" >/dev/null

# A tool terminated by a signal is a completed tool call, not an exec cancellation.
sf_test_tool_execute "$(jq -cn \
  '{id:"signal_1",name:"shell",input:{command:"kill -TERM $$"}}')" 0
jq -e '.exit_code == 143 and .sandboxed == false' <<<"$REPLY" >/dev/null

# A sandboxed bypass executes only with an approval decision from its caller.
load_tools "$(jq -c --arg fence "${commands[fence]:A}" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")" 1
typeset bypass_call=$(jq -cn \
  '{id:"bypass_1",name:"shell",input:{command:"true",request_sandbox_bypass:true,
    sandbox_bypass_reason:"test"}}')
sf_tool_needs_permission shell \
  '{"command":"true","request_sandbox_bypass":true,"sandbox_bypass_reason":"test"}' \
  "$tool_tools" 1
sf_test_tool_execute "$bypass_call" 1
jq -e '.exit_code == 126 and .content == "sandbox bypass denied"' \
  <<<"$REPLY" >/dev/null
sf_test_tool_execute "$bypass_call" 1 denied 'hook said no'
jq -e '.exit_code == 126 and .content == "hook said no"' <<<"$REPLY" >/dev/null
sf_test_tool_execute "$bypass_call" 1 approved
jq -e '.exit_code == 0 and .sandboxed == false' <<<"$REPLY" >/dev/null
if sf_tool_needs_permission shell '{"command":"true"}' "$tool_tools" 1; then
  fail 'a call without a bypass request asked for permission'
fi
sf_tool_needs_permission shell \
  '{"command":"true","request_sandbox_bypass":true}' "$tool_tools" 1 &&
  fail 'a bypass request without a reason was accepted'
(( $? == 2 )) || fail 'a missing bypass reason did not report invalid input'

# Bundled file tools load together and return bounded content or framework diffs.
typeset file_runtime=$(jq -cn --argjson base "$stored_runtime" \
  --arg root "$ROOT/default/tools" \
  --slurpfile read "$ROOT/default/tools/read_file/tool.json" \
  --slurpfile edit "$ROOT/default/tools/edit_file/tool.json" \
  --slurpfile write "$ROOT/default/tools/write_file/tool.json" '
    $base | .harness.tools = [
      {name:"read_file",command:($root + "/read_file/run"),
       settings:(if $read[0].sandbox then {} else null end),manifest:$read[0]},
      {name:"edit_file",command:($root + "/edit_file/run"),
       settings:(if $edit[0].sandbox then {} else null end),manifest:$edit[0]},
      {name:"write_file",command:($root + "/write_file/run"),
       settings:(if $write[0].sandbox then {} else null end),manifest:$write[0]}]
')
print -r -- alpha >"$tmp/file-tool.txt"
tool_cwd=$tmp
load_tools "$(jq -c '.harness.sandbox=true' <<<"$file_runtime")" 1
jq -e 'map(.name) == ["read_file","edit_file","write_file"] and
  all(.[].input_schema.properties; .request_sandbox_bypass.type == "boolean" and
    .sandbox_bypass_reason.minLength == 1) and
  all(.[].description; contains("keep it to one logical operation") | not)' \
  <<<"$tool_schema" >/dev/null
load_tools "$file_runtime"
sf_test_tool_execute '{"id":"read_1","name":"read_file","input":{"file_path":"file-tool.txt"}}' 0
jq -e '.content == "L1-1 of 1\n1\talpha\n"' <<<"$REPLY" >/dev/null
: >"$tmp/empty.txt"
sf_test_tool_execute '{"id":"read_empty","name":"read_file","input":{"file_path":"empty.txt"}}' 0
jq -e '.content == "(empty)\n"' <<<"$REPLY" >/dev/null
sf_test_tool_execute '{"id":"edit_1","name":"edit_file","input":{"file_path":"file-tool.txt","old_string":"alpha","new_string":"beta"}}' 0
jq -e '.content | startswith("@@ -1 +1 @@\n") and contains("-alpha") and contains("+beta")' \
  <<<"$REPLY" >/dev/null
print -r -- $'one\ntwo\nthree\nfour\nfive\nsix\nseven' >"$tmp/context-diff.txt"
sf_test_tool_execute '{"id":"edit_context","name":"edit_file","input":{"file_path":"context-diff.txt","old_string":"four","new_string":"changed"}}' 0
jq -e '.content | (contains(" three\n-four\n+changed\n five") and
  (contains(" two") | not) and (contains(" six") | not))' <<<"$REPLY" >/dev/null
tool_max_capture=64
typeset full_old=oldoldoldoldoldoldoldoldoldoldoldoldoldoldoldold
typeset full_new=newnewnewnewnewnewnewnewnewnewnewnewnewnewnewnew
print -r -- "$full_old" >"$tmp/full-diff.txt"
sf_test_tool_execute "$(jq -cn --arg old "$full_old" --arg new "$full_new" \
  '{id:"edit_full",name:"edit_file",input:{file_path:"full-diff.txt",old_string:$old,new_string:$new}}')" 0
jq -e '.content | length == 64 and startswith("[output truncated]\n")' \
  <<<"$REPLY" >/dev/null
tool_max_capture=$(jq -r '.harness.max_capture_bytes' <<<"$file_runtime")
sf_test_tool_execute '{"id":"edit_2","name":"edit_file","input":{"file_path":"file-tool.txt","old_string":"beta","new_string":"beta"}}' 0
jq -e '.content == "edit_file: file-tool.txt is already up to date\n"' \
  <<<"$REPLY" >/dev/null
mkdir "$tmp/diff-bin"
cat >"$tmp/diff-bin/diff" <<'ZSH'
#!/usr/bin/env zsh
for arg in "$@"; do
  [[ $arg != /dev/null ]] || {
    print -u2 -- 'diff: /dev/null: Operation not permitted'
    exit 2
  }
done
exec /usr/bin/diff "$@"
ZSH
chmod +x "$tmp/diff-bin/diff"
typeset saved_path=$PATH
PATH="$tmp/diff-bin:$PATH"
rehash
sf_test_tool_execute '{"id":"write_1","name":"write_file","input":{"file_path":"created.txt","content":"created\n"}}' 0
PATH=$saved_path
rehash
jq -e '.content | startswith("@@ -0,0 +1 @@\n") and contains("+created")' \
  <<<"$REPLY" >/dev/null
typeset newline_path=$'trailing-newline\n'
sf_test_tool_execute "$(jq -cn --arg path "$newline_path" \
  '{id:"write_2",name:"write_file",input:{file_path:$path,content:"kept\n"}}')" 0
[[ -f "$tmp/$newline_path" ]]

# Sandboxed execution goes through Fence with the frozen package policy and
# executable exposed read-only.
mkdir "$tmp/bin"
cat >"$tmp/bin/fence" <<'ZSH'
#!/usr/bin/env zsh
print -rl -- "$@" >"${0:A:h:h}/fence.args"
print -r -- "$LANG" >"${0:A:h:h}/fence.lang"
print -r -- "$LC_ALL" >"${0:A:h:h}/fence.lc_all"
print -r -- "$LC_CTYPE" >"${0:A:h:h}/fence.lc_ctype"
print -r -- "$HOME" >"${0:A:h:h}/fence.home"
print -r -- "$TMPDIR" >"${0:A:h:h}/fence.tmpdir"
print -r -- "$TMPPREFIX" >"${0:A:h:h}/fence.tmpprefix"
typeset sandbox_log=''
while (( $# )) && [[ $1 != -- ]]; do
  case $1 in
    --fence-log-file) sandbox_log=$2; shift 2 ;;
    --settings) cp -- "$2" "${0:A:h:h}/fence.settings"; shift 2 ;;
    *) shift ;;
  esac
done
(( $# )) && shift
TMPDIR=/tmp/fence "$@"
integer code=$?
[[ ! -f "${0:A:h:h}/fence.violate" ]] ||
  print -r -- '[fence:test] 00:00:00 ✗ blocked' >"$sandbox_log"
exit $code
ZSH
chmod +x "$tmp/bin/fence"
cat >"$tmp/bin/curl" <<'ZSH'
#!/usr/bin/env zsh
print -r -- '# sandboxed markdown'
ZSH
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH"
rehash
typeset fetch_runtime=$(jq -cn --argjson base "$stored_runtime" \
  --arg root "$ROOT/default/tools/fetch_url" \
  --slurpfile manifest "$ROOT/default/tools/fetch_url/tool.json" \
  --slurpfile settings "$ROOT/default/tools/fetch_url/fence.jsonc" '
    $base | .harness.tools = [{
      name:"fetch_url",command:($root + "/run"),
      settings:$settings[0],manifest:$manifest[0]
    }]
')
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$fetch_runtime")"
sf_test_tool_execute \
  '{"id":"fetch_1","name":"fetch_url","input":{"url":"https://example.com"}}' 1
jq -e '.exit_code == 0 and .content == "# sandboxed markdown\n"' <<<"$REPLY" >/dev/null
jq -e '.network.allowedDomains == ["r.jina.ai"] and .filesystem.defaultDenyRead == true' \
  "$tmp/fence.settings" >/dev/null
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")"
sf_test_tool_execute "$(jq -cn --arg command 'printf "%s|%s" "$TMPDIR" "$TMPPREFIX"' \
  '{id:"fence_empty",name:"shell",input:{command:$command}}')" 1
jq -e '.content == "/tmp/fence|/tmp/fence/zsh"' <<<"$REPLY" >/dev/null
if grep -Fx -- '--expose-host-path-rw' "$tmp/fence.args" >/dev/null; then
  fail 'sandbox added an unexpected writable runtime exposure'
fi
assert_equal "${LANG:-C}" "$(<"$tmp/fence.lang")"
assert_equal "$LC_ALL" "$(<"$tmp/fence.lc_all")"
assert_equal "$LC_CTYPE" "$(<"$tmp/fence.lc_ctype")"
assert_equal '' "$(<"$tmp/fence.tmpdir")"
assert_equal /tmp/fence/zsh "$(<"$tmp/fence.tmpprefix")"
assert_equal "$HOME" "$(<"$tmp/fence.home")"
mkdir "$tmp/read dir" "$tmp/write dir"
touch "$tmp/read file" "$tmp/write file"
load_tools "$(jq -c --arg fence "$tmp/bin/fence" --arg read_dir "$tmp/read dir" \
  --arg read_file "$tmp/read file" --arg write_dir "$tmp/write dir" \
  --arg write_file "$tmp/write file" '
  .harness.sandbox=true | .harness.fence=$fence |
  .harness.sandbox_read_paths=[$read_dir,$read_file] |
  .harness.sandbox_write_paths=[$write_dir,$write_file]' <<<"$stored_runtime")"
sf_test_tool_execute "$(jq -cn --arg command 'printf fenced' \
  '{id:"fence_1",name:"shell",input:{command:$command}}')" 1
jq -e '.content == "fenced" and .sandboxed == true' \
  <<<"$REPLY" >/dev/null
grep -Fx -- '--monitor' "$tmp/fence.args" >/dev/null
grep -Fx -- '--fence-log-file' "$tmp/fence.args" >/dev/null
grep -Fx -- '--settings' "$tmp/fence.args" >/dev/null
jq -e '. == {}' "$tmp/fence.settings" >/dev/null
(( $(grep -Fxc -- '--expose-host-path' "$tmp/fence.args") == 4 ))
grep -Fx -- "$tool_dir/run" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/read dir" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/read file" "$tmp/fence.args" >/dev/null
(( $(grep -Fxc -- '--expose-host-path-rw' "$tmp/fence.args") == 2 ))
grep -Fx -- "$tmp/write dir" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/write file" "$tmp/fence.args" >/dev/null
touch "$tmp/fence.violate"
sf_test_tool_execute "$(jq -cn --arg command 'printf blocked; exit 3' \
  '{id:"fence_blocked",name:"shell",input:{command:$command}}')" 1
jq -e '.content == "blocked" and .sandboxed == true and .sandbox_blocked == true' \
  <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn --arg command 'printf noisy' \
  '{id:"fence_noise",name:"shell",input:{command:$command}}')" 1
jq -e '.content == "noisy" and .sandboxed == true and (has("sandbox_blocked") | not)' \
  <<<"$REPLY" >/dev/null
rm "$tmp/fence.violate"
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")"
jq -e '.[0] |
  (.input_schema.properties | has("request_sandbox_bypass") | not) and
  (.description | contains("keep it to one logical operation") | not)' \
  <<<"$tool_schema" >/dev/null
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")" 1
jq -e '.[0].input_schema.properties.request_sandbox_bypass.type == "boolean" and
  .[0].input_schema.properties.sandbox_bypass_reason.minLength == 1 and
  (.[0].input_schema.allOf[0].then.required | index("sandbox_bypass_reason")) != null and
  (.[0].description | contains("keep it to one logical operation"))' \
  <<<"$tool_schema" >/dev/null
