#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

schema_eval() {
  jq -L "$ROOT" -e 'include "lib/runtime"; '"$1"
}

request_eval() {
  jq -L "$ROOT" -e 'include "lib/session"; include "lib/backend"; '"$1"
}

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
    runtime: {
      request: {model: "gpt-4o"},
      system: [],
      backend: {
        command: "/bin/run",
        endpoint: "https://api.openai.com/v1/chat/completions",
        insecure_tls: false,
        http_timeout: 30, http_stall: 10
      },
      harness: {
        sandbox_read_paths: [], sandbox_write_paths: [],
        tools: [], sandbox: true,
        max_requests_per_turn: 50, max_tool_calls_per_request: 20,
        max_capture_bytes: 32768,
        stop: [{command:"/bin/hook",render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]
      }
    }
  }
')
print -r -- "$valid_header" | schema_eval 'canonical_session_header' >/dev/null
for patch in '.extra=true' '.runtime.extra=true'; do
  if jq -c "$patch" <<<"$valid_header" |
      schema_eval 'canonical_session_header' >/dev/null 2>&1; then
    fail "opaque session state was accepted: $patch"
  fi
done
valid_header=$(jq -c '.runtime.harness.user_prompt_submit=[{
  command:"/bin/prompt",render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"},match:{pattern:"^!"},
  help:{usage:"!COMMAND",description:"Run a shell command"}
}]' <<<"$valid_header")
print -r -- "$valid_header" | schema_eval 'canonical_session_header' >/dev/null
typeset permission_header
permission_header=$(jq -c '.runtime.harness.permission_request=[{
  command:"/bin/permission",render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}
}]' <<<"$valid_header")
print -r -- "$permission_header" |
  schema_eval 'canonical_session_header' >/dev/null
for patch in \
  '.runtime.harness.user_prompt_submit[0].match.pattern="["' \
  'del(.runtime.harness.user_prompt_submit[0].match)'; do
  if jq -c "$patch" <<<"$valid_header" |
      schema_eval 'canonical_session_header' >/dev/null 2>&1; then
    fail "invalid hook selection metadata was accepted: $patch"
  fi
done

print -r -- "$valid_header" | jq -c '.runtime.system = ["/system/prompt.md"]' |
  schema_eval 'canonical_session_header' >/dev/null
for system in '["relative.md"]' '"/system/prompt.md"'; do
  if jq -c --argjson system "$system" '.runtime.system = $system' <<<"$valid_header" |
      schema_eval 'canonical_session_header' >/dev/null 2>&1; then
    fail "invalid system paths were accepted in a session header: $system"
  fi
done

# Hook paths must be absolute.
if jq -c '.runtime.harness.stop[0].command = "relative/hook"' <<<"$valid_header" |
    schema_eval 'canonical_session_header' >/dev/null 2>&1; then
  fail 'relative hook path was accepted in session header'
fi
if jq -c '.runtime.harness.sandbox_read_paths = ["relative"]' <<<"$valid_header" |
    schema_eval 'canonical_session_header' >/dev/null 2>&1; then
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
      initial_user_text: "${name}\n${input.command}",
      user_text: "${name}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
      model_text: "${output.stdout}${output.stderr}\nexit ${output.exit_code}",
      permission_user_text: "${input.command}"
    },
    sandbox: true,
    allow_sandbox_bypass: true
  }
')
print -r -- "$valid_manifest" | schema_eval 'tool_manifest' >/dev/null
# Environment names must survive space-separated zsh projection.
for environment in '["DUPLICATE","DUPLICATE"]' '["HAS SPACE"]'; do
  if jq -c --argjson environment "$environment" \
      '.environment = $environment' <<<"$valid_manifest" |
      schema_eval 'tool_manifest' >/dev/null 2>&1; then
    fail "invalid tool environment was accepted: $environment"
  fi
done
print -r -- "$valid_manifest" | jq -c 'del(.render)' |
  schema_eval 'tool_manifest' >/dev/null || fail 'tool manifest required render overrides'
print -r -- "$valid_manifest" | jq -c '.render = {model_text:""}' |
  schema_eval 'tool_manifest' >/dev/null || fail 'tool manifest rejected a partial render override'
print -r -- "$valid_manifest" | jq -c '.render.preview_lines = 3' |
  schema_eval 'tool_manifest' >/dev/null || fail 'tool manifest rejected a preview line limit'
for preview in -1 '"context"'; do
  if jq -c --argjson preview "$preview" '.render.preview_lines = $preview' \
      <<<"$valid_manifest" | schema_eval 'tool_manifest' >/dev/null 2>&1; then
    fail "tool manifest accepted invalid preview lines: $preview"
  fi
done
if print -r -- "$valid_manifest" | jq -c '.render = null' |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest accepted null render overrides'
fi
for manifest in "$ROOT"/share/profiles/default/tools/*/manifest.json; do
  schema_eval 'tool_manifest' <"$manifest" >/dev/null ||
    fail "invalid bundled tool manifest: $manifest"
done

if jq -c '.render = {user_before:"",user_after:"",model_after:""}' \
    <<<"$valid_manifest" | schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest accepted the deleted render vocabulary'
fi
if jq -c '.render.initial_user_text = "${output.stdout}"' <<<"$valid_manifest" |
    schema_eval 'tool_manifest' >/dev/null 2>&1; then
  fail 'tool manifest used output in its initial user text'
fi
typeset tool_header
tool_header=$(jq -cn --argjson header "$valid_header" --argjson manifest "$valid_manifest" '
  $header | .runtime.harness.tools = [{
    name:"shell", command:"/bin/shell-tool", manifest:$manifest, settings:"/etc/fence.jsonc"
  }]
')
print -r -- "$tool_header" | schema_eval 'canonical_session_header' >/dev/null
if jq -c '.runtime.harness.tools[0].manifest |= del(.render.model_text)' <<<"$tool_header" |
    schema_eval 'canonical_session_header' >/dev/null 2>&1; then
  fail 'session header accepted an unnormalized tool render'
fi
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
