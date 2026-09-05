#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-tools-web

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
  "$ROOT/share/default/tools/fetch_url/run" <<<'{"url":"https://example.com/docs?q=reader"}')
assert_equal '# fetched markdown' "$jina_output"
typeset -a expected_jina_args=(
  --disable --silent --show-error --fail-with-body --connect-timeout 10 --max-time 60
  --header 'X-Return-Format: markdown' --
  'https://r.jina.ai/https://example.com/docs?q=reader'
)
assert_equal "${(F)expected_jina_args}" "$(<"$jina_args")"
if PATH="$tmp/jina-bin:$PATH" JINA_TEST_ARGS="$jina_args" \
    "$ROOT/share/default/tools/fetch_url/run" <<<'{"url":"file:///etc/passwd"}' >/dev/null 2>&1; then
  fail 'fetch_url accepted a non-HTTP URL'
fi
if PATH="$tmp/jina-bin:$PATH" JINA_TEST_ARGS="$jina_args" \
    "$ROOT/share/default/tools/fetch_url/run" <<<'{"url":"https://example.com","extra":true}' >/dev/null 2>&1; then
  fail 'fetch_url accepted an unknown input field'
fi
if PATH="$tmp/jina-bin:$PATH" JINA_TEST_ARGS="$jina_args" JINA_TEST_STATUS=22 \
    "$ROOT/share/default/tools/fetch_url/run" <<<'{"url":"https://example.com"}' >/dev/null 2>&1; then
  fail 'fetch_url hid a curl failure'
fi
jq -e '
  .network.allowedDomains == ["r.jina.ai"] and
  .network.allowLocalBinding == false and
  .network.allowLocalOutbound == false and
  .filesystem.defaultDenyRead == true
' "$ROOT/share/default/tools/fetch_url/fence.jsonc" >/dev/null

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
  "$ROOT/share/default/tools/search_web/run" \
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
    "$ROOT/share/default/tools/search_web/run" \
    <<<'{"query":"docs","num_results":1.5}' >/dev/null 2>&1; then
  fail 'search_web accepted a fractional result count'
fi
if PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" \
    "$ROOT/share/default/tools/search_web/run" \
    <<<'{"query":"docs","extra":true}' >/dev/null 2>&1; then
  fail 'search_web accepted an unknown input field'
fi
typeset exa_error='{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"rate limited"}}'
if PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" EXA_TEST_RESPONSE="$exa_error" \
    "$ROOT/share/default/tools/search_web/run" <<<'{"query":"docs"}' >/dev/null 2>&1; then
  fail 'search_web accepted an MCP error response'
fi
if PATH="$tmp/exa-bin:$PATH" EXA_TEST_ARGS="$exa_args" EXA_TEST_STATUS=22 \
    "$ROOT/share/default/tools/search_web/run" <<<'{"query":"docs"}' >/dev/null 2>&1; then
  fail 'search_web hid a curl failure'
fi
jq -e '
  .network.allowedDomains == ["mcp.exa.ai"] and
  .network.allowLocalBinding == false and
  .network.allowLocalOutbound == false and
  .filesystem.defaultDenyRead == true
' "$ROOT/share/default/tools/search_web/fence.jsonc" >/dev/null
