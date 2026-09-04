#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

schema_eval() {
  jq -L "$ROOT" -e 'include "lib/runtime/schema"; '"$1"
}

# Canonical user messages require single text content without NUL bytes.
print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"hello"}]}' |
  schema_eval 'canonical_user_message' >/dev/null

if print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"bad\u0000nul"}]}' |
    schema_eval 'canonical_user_message' >/dev/null 2>&1; then
  fail 'user message with NUL was accepted'
fi

if print -r -- '{"type":"message","role":"user","content":[]}' |
    schema_eval 'canonical_user_message' >/dev/null 2>&1; then
  fail 'empty user content was accepted'
fi

# Canonical assistant messages validate stop reasons and content consistency.
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"hi"}]}' |
  schema_eval 'canonical_assistant_message' >/dev/null

print -r -- '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"c1","name":"shell","input":{}}]}' |
  schema_eval 'canonical_assistant_message' >/dev/null

# Duplicate tool call IDs in the same assistant message are rejected.
if print -r -- '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"dup","name":"shell","input":{}},{"type":"tool_call","id":"dup","name":"shell","input":{}}]}' |
    schema_eval 'canonical_assistant_message' >/dev/null 2>&1; then
  fail 'duplicate tool call IDs were accepted'
fi

# Stop "tool_calls" without tool call items is rejected.
if print -r -- '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"text","text":"no calls"}]}' |
    schema_eval 'canonical_assistant_message' >/dev/null 2>&1; then
  fail 'stop tool_calls without tool calls was accepted'
fi

# Cancellation is recovered with ordinary records rather than a durable stop reason.
if print -r -- '{"type":"message","role":"assistant","stop":"cancelled","content":[{"type":"text","text":"halted"}]}' |
    schema_eval 'canonical_assistant_message' >/dev/null 2>&1; then
  fail 'cancelled assistant stop reason was accepted'
fi

# Canonical requests use exact projected message and tool wrappers.
typeset valid_request
valid_request=$(jq -cn '{
  format_version:1,
  system:"system",
  messages:[
    {role:"user",content:[{type:"text",text:"question"}]},
    {role:"assistant",stop:"tool_calls",content:[
      {type:"reasoning",text:"checking",opaque:{signature:"signed"}},
      {type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}
    ]},
    {role:"tool_result",call_id:"call_1",name:"shell",content:"/tmp",exit_code:0},
    {role:"assistant",stop:"end",content:[{type:"text",text:"done"}]}
  ],
  tools:[{name:"shell",description:"Run a command",input_schema:{
    type:"object",properties:{command:{type:"string"}},required:["command"]
  }}],
  options:{request:{model:"model"}},
  transport:{endpoint:"https://example.com",insecure_tls:false,http_timeout:30,http_stall:10}
}') || fail 'cannot prepare canonical request fixture'
print -r -- "$valid_request" | schema_eval 'canonical_request' >/dev/null

for filter in \
    '.messages[0].content = [{}]' \
    '.messages[1].content[0].extra = true' \
    '.tools[0] = {}' \
    '.options.extra = true' \
    '.transport.extra = true' \
    '.extra = true'; do
  if jq "$filter" <<<"$valid_request" | schema_eval 'canonical_request' >/dev/null 2>&1; then
    fail "canonical request accepted malformed input: $filter"
  fi
done

# Backend response events carry indexed content updates and one terminal response end.
jq -cn '[
  {type:"_assistant_reasoning_opaque",index:0,opaque:{type:"redacted_thinking",data:"secret"}},
  {type:"_assistant_reasoning_delta",index:0,text:"summary"},
  {type:"_assistant_delta",index:1,text:"checking"},
  {type:"_assistant_tool_call_delta",index:2,id:"call_1",name:"shell",input:"{\"command\":"},
  {type:"_assistant_tool_call_delta",index:2,input:"\"pwd\"}"},
  {type:"_turn_usage",input_tokens:10,cached_tokens:4,output_tokens:3},
  {type:"_assistant_response_end",stop:"tool_calls"}
]' | schema_eval 'canonical_backend_response_events' >/dev/null

# Opaque reasoning can exist without display text.
print -r -- '{"type":"_assistant_reasoning_opaque","index":0,"opaque":{}}' |
  schema_eval 'canonical_backend_event' >/dev/null

for event in \
    '{"type":"_assistant_delta","text":"missing index"}' \
    '{"type":"_assistant_tool_call_delta","index":0}' \
    '{"type":"_assistant_tool_call_delta","index":0,"id":"bad id"}' \
    '{"type":"_assistant_response_end","stop":"cancelled"}'; do
  if print -r -- "$event" | schema_eval 'canonical_backend_event' >/dev/null 2>&1; then
    fail "invalid backend event was accepted: $event"
  fi
done

if jq -cn '[
    {type:"_assistant_response_end",stop:"end"},
    {type:"_assistant_delta",index:0,text:"late"}
  ]' | schema_eval 'canonical_backend_response_events' >/dev/null 2>&1; then
  fail 'backend events after response end were accepted'
fi

if jq -cn '[{type:"_assistant_delta",index:0,text:"unfinished"}]' |
    schema_eval 'canonical_backend_response_events' >/dev/null 2>&1; then
  fail 'backend response without response end was accepted'
fi

# Assembly orders indexed blocks, joins deltas, retains opaque data, and uses final usage.
jq -cn '[
  {type:"_assistant_tool_call_delta",index:2,id:"call_1",name:"shell",input:"{\"command\":"},
  {type:"_assistant_reasoning_delta",index:0,text:"think "},
  {type:"_turn_usage",input_tokens:5,output_tokens:1},
  {type:"_assistant_delta",index:1,text:"run "},
  {type:"_assistant_reasoning_opaque",index:0,opaque:{signature:"signed"}},
  {type:"_assistant_tool_call_delta",index:2,input:"\"pwd\"}"},
  {type:"_assistant_reasoning_delta",index:0,text:"first"},
  {type:"_assistant_delta",index:1,text:"this"},
  {type:"_turn_usage",input_tokens:5,cached_tokens:2,output_tokens:4},
  {type:"_assistant_response_end",stop:"tool_calls"}
]' | schema_eval 'assemble_backend_response == {
  type:"message",role:"assistant",stop:"tool_calls",
  content:[
    {type:"reasoning",text:"think first",opaque:{signature:"signed"}},
    {type:"text",text:"run this"},
    {type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}
  ],
  usage:{input_tokens:5,cached_tokens:2,output_tokens:4}
}' >/dev/null

# A length-limited response preserves completed content but discards partial calls.
jq -cn '[
  {type:"_assistant_delta",index:0,text:"visible"},
  {type:"_assistant_tool_call_delta",index:1,id:"call_1",name:"shell",input:"{\"command\":"},
  {type:"_assistant_response_end",stop:"length"}
]' | schema_eval 'assemble_backend_response == {
  type:"message",role:"assistant",stop:"length",content:[{type:"text",text:"visible"}]
}' >/dev/null

for events in \
    '[{"type":"_assistant_delta","index":0,"text":"text"},{"type":"_assistant_reasoning_delta","index":0,"text":"reason"},{"type":"_assistant_response_end","stop":"end"}]' \
    '[{"type":"_assistant_reasoning_opaque","index":0,"opaque":{"a":1}},{"type":"_assistant_reasoning_opaque","index":0,"opaque":{"a":2}},{"type":"_assistant_response_end","stop":"end"}]' \
    '[{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"shell","input":"{}"},{"type":"_assistant_response_end","stop":"end"}]' \
    '[{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"shell","input":"{"},{"type":"_assistant_response_end","stop":"tool_calls"}]' \
    '[{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"shell","input":"{}"},{"type":"_assistant_tool_call_delta","index":1,"id":"call_1","name":"shell","input":"{}"},{"type":"_assistant_response_end","stop":"tool_calls"}]'; do
  if print -r -- "$events" | schema_eval 'assemble_backend_response' >/dev/null 2>&1; then
    fail "invalid backend response was assembled: $events"
  fi
done

# Canonical tool results require numeric exit codes from 0 through 255.
print -r -- '{"type":"message","role":"tool_result","call_id":"c1","name":"shell","content":"out","exit_code":0}' |
  schema_eval 'canonical_tool_result' >/dev/null

print -r -- '{"type":"message","role":"tool_result","call_id":"c1","name":"shell","content":"out","exit_code":0,"sandbox_denial_detected":true}' |
  schema_eval 'canonical_tool_result' >/dev/null

if print -r -- '{"type":"message","role":"tool_result","call_id":"c1","name":"shell","content":"out","exit_code":0,"sandbox_denial_detected":false}' |
    schema_eval 'canonical_tool_result' >/dev/null 2>&1; then
  fail 'false sandbox_denial_detected flag was accepted'
fi

if print -r -- '{"type":"message","role":"tool_result","call_id":"c1","name":"shell","content":"out","exit_code":256}' |
    schema_eval 'canonical_tool_result' >/dev/null 2>&1; then
  fail 'invalid exit code was accepted'
fi

if print -r -- '{"type":"message","role":"tool_result","call_id":"c1","name":"shell","content":"out","exit_code":0,"outcome":"executed"}' |
    schema_eval 'canonical_tool_result' >/dev/null 2>&1; then
  fail 'legacy tool outcome was accepted'
fi

# Canonical context records accept valid optional fields and reject unknown ones.
print -r -- '{"type":"context","hook":"env","content":"data","script":"add_env","prompt":"pwd","status":0}' |
  schema_eval 'canonical_context' >/dev/null

if print -r -- '{"type":"context","hook":"env","content":"data"}' |
    schema_eval 'canonical_context' >/dev/null 2>&1; then
  fail 'context without a script was accepted'
fi

for field in label preface truncated; do
  if jq -cn --arg field "$field" \
      '{type:"context",hook:"env",script:"add_env",content:"data"} + {($field):true}' |
      schema_eval 'canonical_context' >/dev/null 2>&1; then
    fail "context with unknown $field field was accepted"
  fi
done

# Canonical session headers require absolute hook paths and valid structures.
typeset valid_header
valid_header=$(jq -cn '
  {
    type: "session",
    format_version: 1,
    cwd: "/tmp",
    created: "2026-08-18T00:00:00Z",
    profile: {
      request: {model: "gpt-4o"}, system: []
    },
    backend: {
      name: "openai", command: "/bin/run", env_file: "/tmp/.env",
      endpoint: "https://api.openai.com/v1/chat/completions",
      api_key_env: "OPENAI_API_KEY", insecure_tls: false,
      http_timeout: 30, http_stall: 10
    },
    harness: {
      sandbox_read_paths: [], sandbox_write_paths: [],
      fence: "", tools: [], sandbox: true,
      max_requests_per_turn: 50, max_tool_calls_per_request: 20,
      max_capture_bytes: 32768, stop: ["/bin/hook"]
    }
  }
')
print -r -- "$valid_header" | schema_eval 'canonical_session_header(1)' >/dev/null

# Relative hook paths in session headers are rejected.
if jq -c '.harness.stop = ["relative/hook"]' <<<"$valid_header" |
    schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
  fail 'relative hook path was accepted in session header'
fi
if jq -c '.harness.sandbox_read_paths = ["relative"]' <<<"$valid_header" |
    schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
  fail 'relative sandbox read path was accepted in session header'
fi

# Tool manifests validate schema, display references, and bypass rules.
typeset valid_manifest
valid_manifest=$(jq -cn '
  {
    description: "Run shell command",
    input_schema: {
      type: "object",
      properties: {command: {type: "string"}},
      required: ["command"]
    },
    display: {
      summary: [],
      call: {content: ["$command"], format: "sh"},
      permission_preview: {content: ["$command"], format: "sh"},
      result: {content: ["$result_full", "$exit_code"], format: "plain"}
    },
    sandbox: true,
    allow_sandbox_bypass: true
  }
')
print -r -- "$valid_manifest" | schema_eval 'tool_manifest' >/dev/null
for manifest in "$ROOT"/default/tools/*/tool.json; do
  schema_eval 'tool_manifest' <"$manifest" >/dev/null ||
    fail "invalid bundled tool manifest: $manifest"
done

typeset tool_header
tool_header=$(jq -cn --argjson header "$valid_header" --argjson manifest "$valid_manifest" '
  $header | .harness.tools = [{
    name:"shell", command:"/bin/shell-tool", manifest:$manifest, settings:"/etc/fence.jsonc"
  }]
')
print -r -- "$tool_header" | schema_eval 'canonical_session_header(1)' >/dev/null
if jq -c '.harness.tools[0].describe = ""' <<<"$tool_header" |
    schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
  fail 'legacy tool describe path was accepted in session header'
fi

if jq -c '.display.result.content = ["$unknown"]' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest with an unknown result variable was accepted'
fi
if jq -c '.display.result.content = ["$result_preview", "$result_full"]' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest with multiple result content variables was accepted'
fi
if jq -c '.display.summary = null' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest with a null display region was accepted'
fi
if jq -c '.display.call.content = ["$missing"]' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest with an unknown display field reference was accepted'
fi
if jq -c '.display.permission_preview = null' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest with a null permission preview was accepted'
fi
if jq -c '.display.call.format = "not a format"' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest with an invalid display format was accepted'
fi

for field in request_sandbox_bypass sandbox_bypass_reason; do
  if jq -c --arg field "$field" '.input_schema.properties[$field] = {type:"string"}' \
      <<<"$valid_manifest" | schema_eval 'tool_manifest' >/dev/null 2>&1; then
    fail "tool manifest with reserved $field field was accepted"
  fi
done

# A tool manifest with allow_sandbox_bypass=true but sandbox=false is rejected.
if jq -c '.sandbox = false' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'allow_sandbox_bypass with sandbox=false was accepted'
fi
