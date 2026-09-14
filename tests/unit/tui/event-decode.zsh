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

# Decode tool activity.
typeset order shell_runtime
shell_runtime=$(jq -cn \
  --slurpfile shell "$ROOT/share/default/tools/shell/manifest.json" '
  {harness:{tools:[{name:"shell",manifest:$shell[0]}]}}
')
order=$(print -r -- \
    '{"type":"_tool_activity","call_id":"call_1","name":"shell","input":{"command":"true"}}' |
  jq -jRs -L "$ROOT" --argjson runtime "$shell_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_call,call_1,shell,true,shell,0,batch_ok' "$order"

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
    '{"type":"_hook_activity","hook":"unknown","script":"/hooks/check/run","input":""}' \
    '{"type":"_hook_activity","hook":"stop","script":"check","input":""}'; do
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
order=$(print -r -- \
    '{"type":"_tool_activity","call_id":"call_2","name":"read_file","input":{"file_path":"outside.txt","request_sandbox_bypass":true,"sandbox_bypass_reason":"test"}}' |
  jq -jRs -L "$ROOT" --argjson runtime "$read_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_call,call_2,read_file · outside.txt,read_file,0,batch_ok' "$order"

# Decode hook replacement views.
typeset hook_runtime='{"harness":{"stop":[{"command":"/hooks/check/run","environment":[],"render":{"user_before":"${script} · ${input}","user_after":"${script} · ${output.stdout}${output.stderr} (${output.exit_code})","model_after":"${output.stdout}"}}]}}'
order=$(print -r -- \
    '{"type":"hook_result","hook":"stop","script":"/hooks/check/run","input":"answer","stdout":"model body","stderr":"user body","exit_code":10}' |
  jq -jRs -L "$ROOT" --argjson runtime "$hook_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_result,stop,/hooks/check/run,check · model bodyuser body (10),0,1,batch_ok' "$order"

# Any completed hook may address the model.
order=$(print -r -- \
    '{"type":"hook_result","hook":"stop","script":"/hooks/check/run","input":"answer","stdout":"model body","stderr":"user body","exit_code":0}' |
  jq -jRs -L "$ROOT" --argjson runtime "$hook_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_result,stop,/hooks/check/run,check · model bodyuser body (0),0,1,batch_ok' "$order"

# An empty model rendering contributes no model context.
order=$(print -r -- \
    '{"type":"hook_result","hook":"stop","script":"/hooks/check/run","input":"answer","stdout":"model body","stderr":"user body","exit_code":10}' |
  jq -jRs -L "$ROOT" \
    --argjson runtime "$(jq -c '.harness.stop[0].render.model_after = ""' <<<"$hook_runtime")" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_result,stop,/hooks/check/run,check · model bodyuser body (10),0,0,batch_ok' "$order"

# Decode hook activity.
order=$(print -r -- \
    '{"type":"_hook_activity","hook":"stop","script":"/hooks/check/run","input":"answer"}' |
  jq -jRs -L "$ROOT" --argjson runtime "$hook_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_call,stop,/hooks/check/run,check · answer,0,batch_ok' "$order"

# Exact commands select templates even when their display identities collide.
hook_runtime='{"harness":{"stop":[{"command":"/one/check/run","environment":[],"render":{"user_before":"one ${script}","user_after":"one ${script}","model_after":""}},{"command":"/two/check/run","environment":[],"render":{"user_before":"two ${script}","user_after":"two ${script}","model_after":""}}]}}'
order=$(print -r -- \
    '{"type":"_hook_activity","hook":"stop","script":"/two/check/run","input":""}' |
  jq -jRs -L "$ROOT" --argjson runtime "$hook_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_call,stop,/two/check/run,two check,4,batch_ok' "$order"

# Results whose command left the runtime use the default render contract.
order=$(print -r -- \
    '{"type":"hook_result","hook":"session_start","script":"/removed/probe/run","input":"","stdout":"context","stderr":"","exit_code":0}' |
  jq -jRs -L "$ROOT" --argjson runtime '{"harness":{}}' \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'hook_result,session_start,/removed/probe/run,-1,1,batch_ok' "$order"

# Decode shell permissions.
order=$(print -r -- \
    '{"type":"_tool_permission_request","id":"permission_1","reason":"host access","tool":{"name":"shell","input":{"command":"echo hi","request_sandbox_bypass":true}}}' |
  jq -jRs -L "$ROOT" --argjson runtime "$shell_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'permission_request,permission_1,shell,echo hi,host access,plain,batch_ok' "$order"

# Decode tool results.
typeset edit_runtime=$(jq -cn \
  --slurpfile edit "$ROOT/share/default/tools/edit_file/manifest.json" '
  {harness:{tools:[{name:"edit_file",manifest:$edit[0]}]}}
')
order=$(print -r -- \
    '{"type":"tool_result","call_id":"call_2","name":"edit_file","input":{"file_path":"notes.txt"},"stdout":"@@ -1 +1 @@\n-old\n+new","stderr":"","exit_code":0}' |
  jq -jRs -L "$ROOT" --argjson runtime "$edit_runtime" \
    -f "$ROOT/libexec/tui/event-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'tool_result,call_2,edit_file · notes.txt,@@ -1 +1 @@,-old,+new,edit_file,0,batch_ok' "$order"

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
