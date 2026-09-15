#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

schema_eval() {
  jq -L "$ROOT" -e 'include "lib/runtime/schema"; '"$1"
}

request_eval() {
  jq -L "$ROOT" -e 'include "lib/runtime/schema"; include "lib/session/read";
    include "lib/request"; '"$1"
}

# Request messages require one safe text block.
print -r -- '{"type":"user","content":[{"type":"text","text":"hello"}]}' |
  schema_eval 'request_user_message' >/dev/null

if print -r -- '{"type":"user","content":[{"type":"text","text":"bad\u0000nul"}]}' |
    schema_eval 'request_user_message' >/dev/null 2>&1; then
  fail 'user message with NUL was accepted'
fi

if print -r -- '{"type":"user","content":[]}' |
    schema_eval 'request_user_message' >/dev/null 2>&1; then
  fail 'empty user content was accepted'
fi

# Request responses carry no calls in content.
print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"hi"}]}' |
  schema_eval 'request_assistant_message' >/dev/null

print -r -- '{"type":"tool_call","id":"c1","name":"shell","input":{}}' |
  schema_eval 'request_tool_call' >/dev/null

# Requests require canonical projected fields.
typeset valid_request
valid_request=$(jq -cn '{
  format_version:1,
  system:"system",
  messages:[
    {type:"user",content:[{type:"text",text:"question"}]},
    {type:"assistant",stop:"tool_calls",content:[
      {type:"reasoning",text:"checking",opaque:{signature:"signed"}}
    ]},
    {type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}},
    {type:"tool_result",call_id:"call_1",name:"shell",content:"/tmp",exit_code:0},
    {type:"assistant",stop:"end",content:[{type:"text",text:"done"}]}
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
    '.tools[0] = {}' \
    '.extra = true'; do
  if jq "$filter" <<<"$valid_request" | schema_eval 'canonical_request' >/dev/null 2>&1; then
    fail "canonical request accepted malformed input: $filter"
  fi
done

# Backend streams require canonical ordering.
jq -cn '[
  {type:"_assistant_reasoning_opaque",index:0,opaque:{type:"redacted_thinking",data:"secret"}},
  {type:"_assistant_reasoning_delta",index:0,text:"summary"},
  {type:"_assistant_message_delta",index:1,text:"checking"},
  {type:"_assistant_tool_call_delta",index:2,id:"call_1",name:"shell",input:"{\"command\":"},
  {type:"_assistant_tool_call_delta",index:2,input:"\"pwd\"}"},
  {type:"_turn_usage",input_tokens:10,cached_tokens:4,output_tokens:3},
  {type:"_assistant_end",stop:"tool_calls"}
]' | request_eval 'canonical_backend_response_events' >/dev/null

# Opaque reasoning needs no display text.
print -r -- '{"type":"_assistant_reasoning_opaque","index":0,"opaque":{}}' |
  request_eval 'canonical_backend_event' >/dev/null

for event in \
    '{"type":"_assistant_message_delta","text":"missing index"}' \
    '{"type":"_assistant_end","stop":"cancelled"}'; do
  if print -r -- "$event" | request_eval 'canonical_backend_event' >/dev/null 2>&1; then
    fail "invalid backend event was accepted: $event"
  fi
done

if jq -cn '[
    {type:"_assistant_end",stop:"end"},
    {type:"_assistant_message_delta",index:0,text:"late"}
  ]' | request_eval 'canonical_backend_response_events' >/dev/null 2>&1; then
  fail 'backend events after response end were accepted'
fi

if jq -cn '[{type:"_assistant_message_delta",index:0,text:"unfinished"}]' |
    request_eval 'canonical_backend_response_events' >/dev/null 2>&1; then
  fail 'backend response without response end was accepted'
fi

# Response assembly orders and joins blocks, keeping calls inert in content.
jq -cn '[
  {type:"_assistant_tool_call_delta",index:2,id:"call_1",name:"shell",input:"{\"command\":"},
  {type:"_assistant_reasoning_delta",index:0,text:"think "},
  {type:"_turn_usage",input_tokens:5,output_tokens:1},
  {type:"_assistant_message_delta",index:1,text:"run "},
  {type:"_assistant_reasoning_opaque",index:0,opaque:{signature:"signed"}},
  {type:"_assistant_tool_call_delta",index:2,input:"\"pwd\"}"},
  {type:"_assistant_reasoning_delta",index:0,text:"first"},
  {type:"_assistant_message_delta",index:1,text:"this"},
  {type:"_turn_usage",input_tokens:5,cached_tokens:2,output_tokens:4},
  {type:"_assistant_end",stop:"tool_calls"}
]' | request_eval 'assemble_backend_response(canonical_backend_response_events; canonical_response) == {
  type:"assistant",stop:"tool_calls",
  content:[
    {type:"reasoning",text:"think first",opaque:{signature:"signed"}},
    {type:"text",text:"run this"},
    {type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}
  ],
  usage:{input_tokens:5,cached_tokens:2,output_tokens:4}
}' >/dev/null

# Length stops discard partial calls.
jq -cn '[
  {type:"_assistant_message_delta",index:0,text:"visible"},
  {type:"_assistant_tool_call_delta",index:1,id:"call_1",name:"shell",input:"{\"command\":"},
  {type:"_assistant_end",stop:"length"}
]' | request_eval 'assemble_backend_response(canonical_backend_response_events; canonical_response) == {
  type:"assistant",stop:"length",content:[{type:"text",text:"visible"}]
}' >/dev/null

for events in \
    '[{"type":"_assistant_message_delta","index":0,"text":"text"},{"type":"_assistant_reasoning_delta","index":0,"text":"reason"},{"type":"_assistant_end","stop":"end"}]' \
    '[{"type":"_assistant_reasoning_opaque","index":0,"opaque":{"a":1}},{"type":"_assistant_reasoning_opaque","index":0,"opaque":{"a":2}},{"type":"_assistant_end","stop":"end"}]' \
    '[{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"shell","input":"{}"},{"type":"_assistant_end","stop":"end"}]' \
    '[{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"shell","input":"{"},{"type":"_assistant_end","stop":"tool_calls"}]' \
    '[{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"shell","input":"{}"},{"type":"_assistant_tool_call_delta","index":1,"id":"call_1","name":"shell","input":"{}"},{"type":"_assistant_end","stop":"tool_calls"}]'; do
  if print -r -- "$events" | request_eval \
      'assemble_backend_response(canonical_backend_response_events; canonical_response)' \
      >/dev/null 2>&1; then
    fail "invalid backend response was assembled: $events"
  fi
done

# Session headers require canonical runtimes.
typeset valid_header
valid_header=$(jq -cn '
  {
    type: "session",
    format_version: 1,
    cwd: "/tmp",
    created: "2026-08-18T00:00:00Z",
    profile: {request: {model: "gpt-4o"}},
    backend: {
      name: "openai", command: "/bin/run", env_file: "/tmp/.env",
      endpoint: "https://api.openai.com/v1/chat/completions",
      environment: ["OPENAI_API_KEY"], insecure_tls: false,
      http_timeout: 30, http_stall: 10
    },
    harness: {
      sandbox_read_paths: [], sandbox_write_paths: [],
      fence: "", tools: [], sandbox: true,
      max_requests_per_turn: 50, max_tool_calls_per_request: 20,
      max_capture_bytes: 32768,
      stop: [{command:"/bin/hook",environment:["HOOK_MODE"],running:""}]
    }
  }
')
print -r -- "$valid_header" | schema_eval 'canonical_session_header(1)' >/dev/null
valid_header=$(jq -c '.harness.user_prompt_submit=[{
  command:"/bin/prompt",environment:[],running:"",match:{pattern:"^!"},
  help:{usage:"!COMMAND",description:"Run a shell command"}
}]' <<<"$valid_header")
print -r -- "$valid_header" | schema_eval 'canonical_session_header(1)' >/dev/null
typeset permission_header
permission_header=$(jq -c '.harness.permission_request=[{
  command:"/bin/permission",environment:[],running:""
}]' <<<"$valid_header")
print -r -- "$permission_header" |
  schema_eval 'canonical_session_header(1)' >/dev/null
for patch in \
  '.harness.user_prompt_submit[0].match.pattern="["' \
  'del(.harness.user_prompt_submit[0].match)'; do
  if jq -c "$patch" <<<"$valid_header" |
      schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
    fail "invalid hook selection metadata was accepted: $patch"
  fi
done
# Environment names must survive space-separated zsh projection.
for environment in '["DUPLICATE","DUPLICATE"]' '["HAS SPACE"]'; do
  if jq -c --argjson environment "$environment" \
      '.backend.environment = $environment' <<<"$valid_header" |
      schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
    fail "invalid component environment was accepted: $environment"
  fi
done

print -r -- "$valid_header" | jq -c '.profile.system = ["/system/prompt.md"]' |
  schema_eval 'canonical_session_header(1)' >/dev/null
for system in '["relative.md"]' '"/system/prompt.md"'; do
  if jq -c --argjson system "$system" '.profile.system = $system' <<<"$valid_header" |
      schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
    fail "invalid system paths were accepted in a session header: $system"
  fi
done

# Hook paths must be absolute.
if jq -c '.harness.stop[0].command = "relative/hook"' <<<"$valid_header" |
    schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
  fail 'relative hook path was accepted in session header'
fi
if jq -c '.harness.sandbox_read_paths = ["relative"]' <<<"$valid_header" |
    schema_eval 'canonical_session_header(1)' >/dev/null 2>&1; then
  fail 'relative sandbox read path was accepted in session header'
fi

# Tool manifests validate sandboxing.
typeset valid_manifest
valid_manifest=$(jq -cn '
  {
    description: "Run shell command",
    input_schema: {
      type: "object",
      properties: {command: {type: "string"}},
      required: ["command"]
    },
    render: {
      running: "${name}\n${input.command}",
      user: "${name}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
      model: "${output.stdout}${output.stderr}\nexit ${output.exit_code}",
      permission: "${input.command}"
    },
    sandbox: true,
    allow_sandbox_bypass: true
  }
')
print -r -- "$valid_manifest" | schema_eval 'tool_manifest' >/dev/null
for manifest in "$ROOT"/share/default/tools/*/manifest.json; do
  schema_eval 'tool_manifest' <"$manifest" >/dev/null ||
    fail "invalid bundled tool manifest: $manifest"
done

if jq -c '.render = {user_before:"",user_after:"",model_after:""}' \
    <<<"$valid_manifest" | schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest accepted the deleted render vocabulary'
fi
if jq -c '.render.running = "${output.stdout}"' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest used output in its running text'
fi

typeset tool_header
tool_header=$(jq -cn --argjson header "$valid_header" --argjson manifest "$valid_manifest" '
  $header | .harness.tools = [{
    name:"shell", command:"/bin/shell-tool", manifest:$manifest, settings:"/etc/fence.jsonc"
  }]
')
print -r -- "$tool_header" | schema_eval 'canonical_session_header(1)' >/dev/null
for field in request_sandbox_bypass sandbox_bypass_reason; do
  if jq -c --arg field "$field" '.input_schema.properties[$field] = {type:"string"}' \
      <<<"$valid_manifest" | schema_eval 'tool_manifest' >/dev/null 2>&1; then
    fail "tool manifest with reserved $field field was accepted"
  fi
done

# Sandbox bypass requires sandboxing.
if jq -c '.sandbox = false' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'allow_sandbox_bypass with sandbox=false was accepted'
fi
