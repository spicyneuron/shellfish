#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

# A canonical exec stream covering each event family decodes without error.
cat <<'STREAM' |
{"type":"session","format_version":1,"cwd":"/tmp","created":"2026-01-01T00:00:00Z","profile":{"request":{"model":"test"}},"backend":{"name":"test","command":"/usr/bin/false","endpoint":"https://example.invalid","api_key_env":"","env_file":"","insecure_tls":false,"http_timeout":30,"http_stall":10},"harness":{"sandbox_read_paths":[],"sandbox_write_paths":[],"fence":"","tools":[],"sandbox":false,"max_requests_per_turn":8,"max_tool_calls_per_request":16,"max_capture_bytes":65536}}
{"type":"system","content":"instructions"}
{"type":"_backend_request_start"}
{"type":"_assistant_reasoning_delta","text":"why","seq":0}
{"type":"_assistant_delta","text":"hi\n","seq":1}
{"type":"_turn_usage","input_tokens":14,"output_tokens":2}
{"type":"_turn_usage","input_tokens":100,"cached_tokens":85,"output_tokens":100}
{"type":"_hook_display","event":"stop","hook":"/tmp/check","text":"done"}
{"type":"_exec_error","message":"recoverable"}
{"type":"_handoff","argv":["/usr/bin/env","printf","%s","done"]}
{"type":"message","role":"user","content":[{"type":"text","text":"hi"}]}
{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"hi\n"}],"usage":{"input_tokens":14,"output_tokens":2}}
STREAM
  jq -jRs -L "$ROOT/lib" --argjson runtime null \
    -f "$ROOT/lib/chat/event-decode.jq" >/dev/null

if print -r -- '{"type":"_backend_request_start","unexpected":true}' |
    jq -jRs -L "$ROOT/lib" --argjson runtime null \
      -f "$ROOT/lib/chat/event-decode.jq" >/dev/null 2>&1; then
  fail 'malformed backend request start was accepted'
fi

typeset order
order=$(print -r -- \
    '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"shell","input":{}}]}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime null \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'assistant_commit,tool_call,call_1,shell,{},json,batch_ok' "$order"

typeset error expected
for error expected in \
    'provider request limit reached: 50' 'Turn limit reached,This turn reached the maximum of 50 provider requests.' \
    'openai: credentials rejected (HTTP 401)' 'Authentication failed,openai: credentials rejected (HTTP 401)' \
    'openai: credentials rejected (HTTP 401); no API key was supplied' 'API key required,openai: credentials rejected (HTTP 401); no API key was supplied' \
    'openai: no API key was supplied' 'API key required,openai: no API key was supplied' \
    'codex: Codex credentials are unavailable; authenticate using Codex and retry' 'Authentication required,codex: Codex credentials are unavailable; authenticate using Codex and retry' \
    'openai: request timed out (curl status 28)' 'Request timed out,openai: request timed out (curl status 28)' \
    'openai: TLS connection failed (curl status 60)' 'Provider connection failed,openai: TLS connection failed (curl status 60)' \
    'openai: HTTP 429: slow down' 'Provider rate limit reached,openai: HTTP 429: slow down' \
    'openai: HTTP 400: bad request' 'Provider request failed,openai: HTTP 400: bad request' \
    'session is busy: /tmp/session.jsonl' 'Session busy,session is busy: /tmp/session.jsonl' \
    'session working directory is unavailable: /tmp/gone' 'Working directory unavailable,session working directory is unavailable: /tmp/gone' \
    'cannot prepare hook captures' 'Hook failed,cannot prepare hook captures' \
    'cannot inspect frozen runtime' 'Turn failed,cannot inspect frozen runtime'; do
  order=$(jq -cn --arg message "$error" '{type:"_exec_error",message:$message}' |
    jq -jRs -L "$ROOT/lib" --argjson runtime null \
      -f "$ROOT/lib/chat/event-decode.jq" |
    tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
  assert_equal "exec_error,$expected,batch_ok" "$order"
done

order=$(print -r -- \
    '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_2","name":"read_file","input":{"file_path":"outside.txt","request_sandbox_bypass":true,"sandbox_bypass_reason":"test"}}]}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime null \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'assistant_commit,tool_call,call_2,read_file unsandboxed,{"file_path":"outside.txt"},json,batch_ok' "$order"

order=$(print -r -- \
    '{"type":"context","tag":"user_prompt_submit","hook":"hook name","prompt":"prompt","status":0,"content":"body"}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime null \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'context,hook name,user_prompt_submit prompt,body,batch_ok' "$order"

order=$(print -r -- \
    '{"type":"_tool_permission_request","id":"permission_1","reason":"host access","tool":{"name":"shell","input":{"command":"echo hi","request_sandbox_bypass":true}}}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime null \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'permission_request,permission_1,shell,echo hi,host access,sh,batch_ok' "$order"

order=$(print -r -- \
    '{"type":"_tool_permission_request","id":"permission_2","reason":"host access","tool":{"name":"read_file","input":{"file_path":"outside.txt","request_sandbox_bypass":true,"sandbox_bypass_reason":"host access"}}}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime null \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'permission_request,permission_2,read_file,{"file_path":"outside.txt"},host access,json,batch_ok' "$order"

typeset edit_runtime=$(jq -cn \
  --slurpfile edit "$ROOT/default/tools/edit_file/tool.json" '
  {harness:{tools:[{name:"edit_file",manifest:$edit[0]}]}}
')
order=$(print -r -- \
    '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_3","name":"edit_file","input":{"file_path":"notes.json","old_string":"a","new_string":"b"}}]}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime "$edit_runtime" \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'assistant_commit,tool_call,call_3,edit_file,notes.json,plain,batch_ok' "$order"

order=$(print -r -- \
    '{"type":"message","role":"tool_result","call_id":"call_2","name":"edit_file","content":"@@ -1 +1 @@\n-old\n+new","exit_code":0,"result_type":"file_diff"}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime "$edit_runtime" \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_result,call_2,hidden,@@ -1 +1 @@,-old,+new,file_diff,full,batch_ok' "$order"

typeset handoff
handoff=$(print -r -- '{"type":"_handoff","argv":["/tmp/custom command","","arg"]}' |
  jq -jRs -L "$ROOT/lib" --argjson runtime null \
    -f "$ROOT/lib/chat/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'handoff,["/tmp/custom command","","arg"],batch_ok' "$handoff"

typeset invalid
for invalid in \
    '{"type":"_handoff","argv":[]}' \
    '{"type":"_handoff","argv":[""]}' \
    '{"type":"_handoff","argv":["cmd",1]}' \
    '{"type":"_handoff","argv":["cmd","bad\u0000arg"]}'; do
  if print -r -- "$invalid" |
      jq -jRs -L "$ROOT/lib" --argjson runtime null \
        -f "$ROOT/lib/chat/event-decode.jq" >/dev/null 2>&1; then
    fail "invalid handoff was accepted: $invalid"
  fi
done

if print -r -- '{"type":"message","role":"user"}' |
    jq -jRs -L "$ROOT/lib" --argjson runtime null \
      -f "$ROOT/lib/chat/event-decode.jq" \
      >/dev/null 2>&1; then
  fail 'malformed canonical exec record was accepted'
fi
