#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

schema_eval() {
  jq -L "$ROOT" -e 'include "lib/profile"; '"$1"
}

request_eval() {
  jq -L "$ROOT" -e 'include "lib/session"; include "lib/backend"; '"$1"
}

# The decoder's NUL-separated fields, one per line.
decode() {
  jq -L "$ROOT" -jn 'include "lib/session"; include "lib/backend";
    decode_backend_response(canonical_response)' | tr '\0' '\n'
}

# Deltas pass through, then one complete response ends the stream.
typeset decoded
decoded=$(print -rl -- \
  '{"type":"_assistant_reasoning_delta","text":"think"}' \
  '{"type":"_assistant_message_delta","text":"run"}' \
  '{"type":"assistant","stop":"tool_calls","content":[{"type":"reasoning","text":"think","opaque":{"signature":"signed"}},{"type":"text","text":"run"},{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"pwd"}}],"usage":{"input_tokens":5,"output_tokens":1}}' |
  decode) || fail 'a valid adapter stream was rejected'
assert_equal 'event
{"type":"_assistant_reasoning_delta","text":"think"}
event
{"type":"_assistant_message_delta","text":"run"}
end
{"type":"assistant","stop":"tool_calls","content":[{"type":"reasoning","text":"think","opaque":{"signature":"signed"}},{"type":"text","text":"run"},{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"pwd"}}],"usage":{"input_tokens":5,"output_tokens":1}}' "$decoded"

# The decoder adds no deltas the adapter did not stream.
decoded=$(print -r -- '{"type":"assistant","stop":"end","content":[{"type":"reasoning","text":"","opaque":{}},{"type":"text","text":"done"}]}' |
  decode) || fail 'a response without deltas was rejected'
assert_equal 'end
{"type":"assistant","stop":"end","content":[{"type":"reasoning","text":"","opaque":{}},{"type":"text","text":"done"}]}' "$decoded"

for stream in \
    '{"type":"_assistant_message_delta","index":0,"text":"indexed"}' \
    '{"type":"_turn_usage","input_tokens":1,"output_tokens":1}' \
    '{"type":"assistant","stop":"cancelled","content":[{"type":"text","text":"a"}]}' \
    '{"type":"assistant","stop":"end","content":[{"type":"tool_call","id":"c1","name":"shell","input":{}}]}' \
    '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"a"}]}' \
    $'{"type":"assistant","stop":"end","content":[]}\n{"type":"_assistant_message_delta","text":"late"}'; do
  if print -r -- "$stream" | decode >/dev/null 2>&1; then
    fail "invalid adapter stream was accepted: $stream"
  fi
done

# A cancelled request keeps the text and reasoning its deltas streamed.
jq -cn '[
  {type:"_assistant_reasoning_delta",text:"think "},
  {type:"_assistant_reasoning_delta",text:"first"},
  {type:"_assistant_message_delta",text:"run "},
  {type:"_assistant_message_delta",text:"this"}
]' | request_eval 'backend_delta_response == {type:"assistant",stop:"cancelled",
  content:[{type:"reasoning",text:"think first"},{type:"text",text:"run this"}]}' >/dev/null ||
  fail 'deltas did not join into a cancelled response'
jq -cn '[{type:"_assistant_message_delta",text:""}]' |
  request_eval '[backend_delta_response] == []' >/dev/null ||
  fail 'empty deltas became a cancelled response'

# A session header holds a complete profile and model with stored references.
typeset valid_header
valid_header=$(jq -cn '
  {
    type: "session",
    format_version: 1,
    cwd: "~/project",
    created: "2026-08-18T00:00:00Z",
    model: {
      adapter: "@backends/openai",
      endpoint: "https://api.openai.com/v1/chat/completions",
      request: {model: "gpt-4o"},
      context_window: 128000
    },
    profile: {
      system: [{text: "inline"}],
      tools: ["@tools/shell", "~/tools/jira"],
      hooks: ["/bin/hook", "@hooks/stop"],
      config: {example:["./literal", null, false]},
      sandbox: {enabled: true, read: ["~/cache"], write: []}
    }
  }
')
print -r -- "$valid_header" | schema_eval 'canonical_session_header' >/dev/null
print -r -- "$valid_header" | jq -c 'del(.profile.config)' |
  schema_eval 'canonical_session_header' >/dev/null
print -r -- "$valid_header" | jq -c '.model.context_window = null' |
  schema_eval 'canonical_session_header' >/dev/null
print -r -- "$valid_header" | jq -c 'del(.model.context_window)' |
  schema_eval 'canonical_session_header' >/dev/null
for patch in '.extra=true' '.profile.extra=true' '.profile.env={}' \
    '.profile.config=null' '.profile.config=[]' '.profile.config=false' \
    '.profile."$schema"="x"' 'del(.profile.hooks)' 'del(.profile.sandbox)' \
    '.model.extra=true' 'del(.model.endpoint)' 'del(.model.request.model)' \
    '.model.context_window=0' 'del(.model)' '.profile.model=.model' '.profile.hooks={}' \
    '.profile.hooks=[{command:"/bin/hook"}]' '.profile.system=["@system/general.md"]' \
    '.profile.system=[{text:1}]' '.profile.sandbox=true' '.profile.sandbox.extra=1' \
    '.profile.tools=["shell"]' '.profile.tools=["/a/shell","/b/shell"]' \
    '.model.adapter="./openai"' '.profile.system=[{text:""}]' '.profile.system+=[{text:"two"}]' \
    '.profile.sandbox.read=["relative"]' \
    '.cwd="./project"'; do
  if jq -c "$patch" <<<"$valid_header" |
      schema_eval 'canonical_session_header' >/dev/null 2>&1; then
    fail "invalid session header was accepted: $patch"
  fi
done

# Stored forms round-trip through expansion.
jq -L "$ROOT" -e --arg share /opt/sf/share --arg home /home/me '
  include "lib/profile";
  {profile, model} as $stored |
  ($stored | header_expand($share; $home)) as $expanded |
  $expanded.profile.tools == ["/opt/sf/share/tools/shell", "/home/me/tools/jira"] and
  $expanded.profile.sandbox.read == ["/home/me/cache"] and
  $expanded.model.adapter == "/opt/sf/share/backends/openai" and
  ($expanded | header_store($share; $home)) == $stored
' <<<"$valid_header" >/dev/null || fail 'stored profile paths did not round-trip'

# Any path under the bundled root stores with "@", including sandbox grants.
jq -L "$ROOT" -e --arg share /opt/sf/share --arg home /home/me '
  include "lib/profile";
  header_expand($share; $home) |
  .profile.tools = ["/opt/sf/share/profiles/default/tools/shell", "/opt/other/jira"] |
  .profile.sandbox.write = ["/opt/sf/share/tools"] |
  header_store($share; $home) |
  .profile.tools == ["@profiles/default/tools/shell", "/opt/other/jira"] and
  .profile.sandbox.write == ["@tools"]
' <<<"$valid_header" >/dev/null || fail 'bundled paths did not store with "@"'

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
    user_text: "${input.command}\n${output.stdout}",
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
print -r -- "$valid_manifest" | jq -c 'del(.user_text)' |
  schema_eval 'tool_manifest' >/dev/null || fail 'tool manifest required its templates'
for manifest in "$ROOT"/share/tools/*/manifest.json; do
  schema_eval 'tool_manifest' <"$manifest" >/dev/null ||
    fail "invalid bundled tool manifest: $manifest"
done

for manifest in '.render = {}' '.user_text = "${output.unknown}"' \
    '.user_text = "${input.missing}"'; do
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
