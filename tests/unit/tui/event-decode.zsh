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

# Decode generic tool calls.
typeset order
order=$(print -r -- \
    '{"type":"tool_call","id":"call_1","name":"shell","input":{}}' |
  jq -jRs -L "$ROOT" --argjson runtime null \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_call,call_1,shell,{},json,batch_ok' "$order"

# Format usage with context.
typeset usage
usage=$(print -r -- \
    '{"type":"assistant","stop":"end","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":12400,"cached_tokens":10478,"output_tokens":900}}' |
  jq -jRs -L "$ROOT" --argjson runtime \
    '{"profile":{"context_window":264000}}' -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'turn_usage,12k ↑ 85% ⦿ 900 ↓ 5% of 264k ◔,batch_ok' "$usage"

# Decode multiline errors.
order=$(print -r -- '{"type":"turn_error","message":"Hook failed.\ninvalid output"}' |
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
for invalid in '{"type":"turn_error","message":1}' \
    '{"type":"_assistant_message_delta","text":"missing index"}' \
    '{"type":"_hook_activity","hook":"unknown","script":"check","text":"Working"}'; do
  if print -r -- "$invalid" |
      jq -jRs -L "$ROOT" --argjson runtime null \
        -f "$ROOT/libexec/tui/event-decode.jq" >/dev/null 2>&1; then
    fail "invalid event was accepted: $invalid"
  fi
done

# Decode unsandboxed tool calls.
typeset read_runtime=$(jq -cn \
  --slurpfile read "$ROOT/share/default/tools/read_file/manifest.json" '
  {harness:{tools:[{name:"read_file",manifest:$read[0]}]}}
')
typeset shell_runtime=$(jq -cn \
  --slurpfile shell "$ROOT/share/default/tools/shell/manifest.json" '
  {harness:{tools:[{name:"shell",manifest:$shell[0]}]}}
')
order=$(print -r -- \
    '{"type":"tool_call","id":"call_2","name":"read_file","input":{"file_path":"outside.txt","request_sandbox_bypass":true,"sandbox_bypass_reason":"test"}}' |
  jq -jRs -L "$ROOT" --argjson runtime "$read_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_call,call_2,read_file,outside.txt · unsandboxed,plain,batch_ok' "$order"

# Decode hook results.
order=$(print -r -- \
    '{"type":"hook_result","hook":"user_prompt_submit","script":"hook name","prompt":"prompt","status":0,"model_context":"model body","user_context":"user body"}' |
  jq -jRs -L "$ROOT" --argjson runtime null \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_result,hook name,user_prompt_submit · prompt · status 0,model body,user body,batch_ok' "$order"

# Decode hook activity.
order=$(printf '%s\n' \
    '{"type":"_hook_activity","hook":"stop","script":"check","text":"Checking"}' \
    '{"type":"_hook_activity","text":""}' |
  jq -jRs -L "$ROOT" --argjson runtime null \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_activity,stop,check,Checking,hook_activity,batch_ok' "$order"

# Decode shell permissions.
order=$(print -r -- \
    '{"type":"_tool_permission_request","id":"permission_1","reason":"host access","tool":{"name":"shell","input":{"command":"echo hi","request_sandbox_bypass":true}}}' |
  jq -jRs -L "$ROOT" --argjson runtime "$shell_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'permission_request,permission_1,shell,echo hi,host access,sh,batch_ok' "$order"

# Decode tool results.
typeset edit_runtime=$(jq -cn \
  --slurpfile edit "$ROOT/share/default/tools/edit_file/manifest.json" '
  {harness:{tools:[{name:"edit_file",manifest:$edit[0]}]}}
')
order=$(print -r -- \
    '{"type":"tool_result","call_id":"call_2","name":"edit_file","content":"@@ -1 +1 @@\n-old\n+new","exit_code":0,"sandbox_denial_detected":true}' |
  jq -jRs -L "$ROOT" --argjson runtime "$edit_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_result,call_2,hidden,@@ -1 +1 @@,-old,+new,file_diff,full,sandbox_denial,batch_ok' "$order"

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
