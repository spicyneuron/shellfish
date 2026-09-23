#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

schema_eval() {
  jq -L "$ROOT" -e 'include "lib/profile"; '"$1"
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

# A session header holds a complete profile with stored references.
typeset valid_header
valid_header=$(jq -cn '
  {
    type: "session",
    format_version: 1,
    cwd: "~/project",
    created: "2026-08-18T00:00:00Z",
    profile: {
      request: {model: "gpt-4o"},
      system: ["@default/system/general.md"],
      backend: {
        adapter: "@default/backends/openai",
        endpoint: "https://api.openai.com/v1/chat/completions",
        insecure_tls: false,
        http_timeout: 30, http_stall: 10
      },
      tools: ["@default/tools/shell", "~/tools/jira"],
      hooks: {stop: ["/bin/hook", "@default/hooks/stop"]},
      sandbox: true, sandbox_read_paths: ["~/cache"], sandbox_write_paths: [],
      max_requests_per_turn: 50, max_tool_calls_per_request: 20,
      max_capture_bytes: 32768
    }
  }
')
print -r -- "$valid_header" | schema_eval 'canonical_session_header' >/dev/null
for patch in '.extra=true' '.profile.extra=true' '.profile.extend=["default"]' \
    '.profile."$schema"="x"' 'del(.profile.max_capture_bytes)' 'del(.profile.hooks)' \
    'del(.profile.backend.endpoint)' 'del(.profile.request.model)' \
    '.profile.hooks.stop=[{command:"/bin/hook"}]' '.profile.system=["relative.md"]' \
    '.profile.tools=["shell"]' '.profile.tools=["/a/shell","/b/shell"]' \
    '.profile.backend.adapter="./openai"' '.profile.sandbox_read_paths=["relative"]' \
    '.cwd="./project"'; do
  if jq -c "$patch" <<<"$valid_header" |
      schema_eval 'canonical_session_header' >/dev/null 2>&1; then
    fail "invalid session header was accepted: $patch"
  fi
done

# Stored forms round-trip through expansion.
jq -L "$ROOT" -e --arg share /opt/sf/share --arg home /home/me '
  include "lib/profile";
  .profile as $stored |
  ($stored | profile_expand($share; $home)) as $expanded |
  $expanded.tools == ["/opt/sf/share/profiles/default/tools/shell", "/home/me/tools/jira"] and
  $expanded.sandbox_read_paths == ["/home/me/cache"] and
  ($expanded | profile_store($share; $home)) == $stored
' <<<"$valid_header" >/dev/null || fail 'stored profile paths did not round-trip'

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
    user_text: "${name}\n${input.command}",
    user_permission: "${input.command}",
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
print -r -- "$valid_manifest" | jq -c 'del(.user_text, .user_permission)' |
  schema_eval 'tool_manifest' >/dev/null || fail 'tool manifest required its templates'
for manifest in "$ROOT"/share/profiles/default/tools/*/manifest.json; do
  schema_eval 'tool_manifest' <"$manifest" >/dev/null ||
    fail "invalid bundled tool manifest: $manifest"
done

for manifest in '.render = {}' '.user_text = "${output.stdout}"' \
    '.user_permission = "${input.missing}"'; do
  if jq -c "$manifest" <<<"$valid_manifest" |
      schema_eval 'tool_manifest' >/dev/null 2>&1; then
    fail "tool manifest was accepted: $manifest"
  fi
done
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
