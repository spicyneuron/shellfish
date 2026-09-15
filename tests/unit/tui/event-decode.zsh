#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

# Decode tool-call response framing.
typeset response
response=$(printf '%s\n' \
    '{"type":"_assistant_tool_call_delta","index":0,"id":"call_1"}' \
    '{"type":"_assistant_reasoning_opaque","index":1,"opaque":{"signature":"s"}}' \
    '{"type":"_assistant_end","stop":"tool_calls"}' |
  jq -jRs -L "$ROOT" --argjson runtime null \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal \
  'assistant_tool_call_delta,0,assistant_reasoning_opaque,1,assistant_end,batch_ok' \
  "$response"

# Reject malformed request starts.
if print -r -- '{"type":"_assistant_start","unexpected":true}' |
    jq -jRs -L "$ROOT" --argjson runtime null \
      -f "$ROOT/libexec/tui/event-decode.jq" >/dev/null 2>&1; then
  fail 'malformed backend request start was accepted'
fi

# Decode tool activity from ready text.
typeset order
order=$(print -r -- \
    '{"type":"_tool_activity","id":"call_1","name":"shell","input":{"command":"true"},"user_text":"shell\ntrue"}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_call,call_1,shell,true,shell,tool,batch_ok' "$order"

# Format usage with context.
typeset usage
usage=$(print -r -- \
    '{"type":"assistant","stop":"end","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":12400,"cached_tokens":10478,"output_tokens":900}}' |
  jq -jRs -L "$ROOT" --argjson runtime \
    '{"profile":{"context_window":264000}}' -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'turn_usage,12k ↑ 85% ⦿ 900 ↓ 5% of 264k ◔,batch_ok' "$usage"

# Decode multiline errors.
order=$(print -r -- '{"type":"error","user_text":"Hook failed.\ninvalid output"}' |
  jq -jRs -L "$ROOT" --argjson runtime null \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'error,Hook failed.,invalid output,end,batch_ok' "$order"

# Validate session preparation.
typeset preparation
preparation=$(jq -cn --slurpfile records "$SF_TEST_SESSIONS/header-only.jsonl" \
  '{type:"_session_prepare",path:"/tmp/new.jsonl",records:($records +
    [{type:"system",content:"startup system"}])}')
order=$(print -r -- "$preparation" |
  jq -jRs -L "$ROOT" --argjson runtime null -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n')
[[ $order == $'session_prepare\n'*$'\nstartup system\n'* ]] ||
  fail 'preparation did not expose its runtime and system'
for invalid in '.path="relative"' '.records=[]' '.presentation={}'; do
  if jq -c "$invalid" <<<"$preparation" |
      jq -jRs -L "$ROOT" --argjson runtime null \
        -f "$ROOT/libexec/tui/event-decode.jq" >/dev/null 2>&1; then
    fail "invalid preparation was accepted: $invalid"
  fi
done

# Reject malformed events.
for invalid in '{"type":"error","user_text":1}' \
    '{"type":"_assistant_message_delta","text":"missing index"}' \
    '{"type":"_hook_activity","hook":"unknown","id":"1","name":"check","input":""}' \
    '{"type":"_hook_activity","hook":"stop","id":"bad id","name":"check","input":""}' \
    '{"type":"_hook_activity","hook":"stop","id":"1","name":"","input":""}'; do
  if print -r -- "$invalid" |
      jq -jRs -L "$ROOT" --argjson runtime null \
        -f "$ROOT/libexec/tui/event-decode.jq" >/dev/null 2>&1; then
    fail "invalid event was accepted: $invalid"
  fi
done

# Decode unsandboxed tool calls.
order=$(print -r -- \
    '{"type":"_tool_activity","id":"call_2","name":"read_file","input":{"file_path":"outside.txt","request_sandbox_bypass":true,"sandbox_bypass_reason":"test"},"user_text":"read_file · outside.txt"}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_call,call_2,read_file · outside.txt,read_file,tool,batch_ok' "$order"

# Hook results and activity decode to id, ready text, and name alone.
order=$(print -r -- \
    '{"type":"hook_result","lifecycle":"stop","id":"1","name":"check","input":"answer","executable":"/hooks/check/run","user_text":"check · body (10)","model_text":"body","exit_code":10}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_result,1,check · body (10),check,context,batch_ok' "$order"

# A result with no user text still settles its activity.
order=$(print -r -- \
    '{"type":"hook_result","lifecycle":"session_start","id":"3","name":"probe","input":"","model_text":"context","exit_code":0}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_result,3,probe,context,batch_ok' "$order"

# Silent activity is not shown at all.
order=$(print -r -- \
    '{"type":"_hook_activity","hook":"stop","id":"4","name":"check","input":"answer","executable":"/hooks/check/run","user_text":"check · answer"}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_call,4,check · answer,check,notice,batch_ok' "$order"
order=$(print -r -- \
    '{"type":"_hook_activity","hook":"stop","id":"5","name":"check","input":"answer","executable":"/hooks/check/run"}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'batch_ok' "$order"

# Decode shell permissions.
order=$(print -r -- \
    '{"type":"_tool_permission_request","id":"permission_1","reason":"host access","preview":"echo hi","tool":{"id":"call_1","name":"shell","input":{"command":"echo hi","request_sandbox_bypass":true}}}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'permission_request,permission_1,shell,echo hi,host access,plain,batch_ok' "$order"

# Decode tool results.
order=$(print -r -- \
    '{"type":"tool_result","id":"call_2","name":"edit_file","input":{"file_path":"notes.txt"},"exit_code":0,"user_text":"edit_file · notes.txt\n@@ -1 +1 @@\n-old\n+new","model_text":"@@ -1 +1 @@\n-old\n+new"}' |
  jq -jRs -L "$ROOT" --argjson runtime '{}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_result,call_2,edit_file · notes.txt,@@ -1 +1 @@,-old,+new,edit_file,tool,batch_ok' "$order"

# Decode handoffs.
typeset handoff
handoff=$(print -r -- '{"type":"_handoff","argv":["/tmp/custom command","","arg"]}' |
  jq -jRs -L "$ROOT" --argjson runtime null \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'handoff,["/tmp/custom command","","arg"],batch_ok' "$handoff"

# Decode runtime updates.
typeset updated_runtime session_update
updated_runtime=$(head -n 1 "$ROOT/tests/fixtures/session/header-only.jsonl" |
  jq -c 'del(.type,.format_version,.cwd,.created) | .profile.context_window = null')
session_update=$(jq -cn --argjson runtime "$updated_runtime" \
    '{type:"_session_update",runtime:$runtime}' |
  jq -jRs -L "$ROOT" --argjson runtime null \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal "session_update,$updated_runtime,batch_ok" "$session_update"

# Reject malformed handoffs.
for invalid in \
    '{"type":"_handoff","argv":[]}' \
    '{"type":"_handoff","argv":["cmd","bad\u0000arg"]}'; do
  if print -r -- "$invalid" |
      jq -jRs -L "$ROOT" --argjson runtime null \
        -f "$ROOT/libexec/tui/event-decode.jq" >/dev/null 2>&1; then
    fail "invalid handoff was accepted: $invalid"
  fi
done

# Reject incomplete runtime updates.
if print -r -- '{"type":"_session_update","runtime":{}}' |
    jq -jRs -L "$ROOT" --argjson runtime null \
      -f "$ROOT/libexec/tui/event-decode.jq" >/dev/null 2>&1; then
  fail 'invalid session update was accepted'
fi

# Reject header metadata in updates.
if jq -cn --argjson runtime "$(head -n 1 "$ROOT/tests/fixtures/session/header-only.jsonl")" \
    '{type:"_session_update",runtime:$runtime}' |
    jq -jRs -L "$ROOT" --argjson runtime null \
      -f "$ROOT/libexec/tui/event-decode.jq" >/dev/null 2>&1; then
  fail 'session update containing header metadata was accepted'
fi

# Reject malformed durable records.
if print -r -- '{"type":"user"}' |
    jq -jRs -L "$ROOT" --argjson runtime null \
      -f "$ROOT/libexec/tui/event-decode.jq" \
      >/dev/null 2>&1; then
  fail 'malformed canonical exec record was accepted'
fi
