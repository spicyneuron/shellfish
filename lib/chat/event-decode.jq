include "runtime/schema";
include "chat/display-fields";

def event_fields($event_runtime):
  if .type == "_assistant_delta" then
    ["assistant_delta", .text]
  elif .type == "_assistant_reasoning_delta" then
    ["assistant_reasoning_delta", .text]
  elif . == {type:"_backend_request_start"} then
    ["backend_request_start"]
  elif .type == "_turn_usage" then
    turn_usage_fields($event_runtime.profile.context_window // null)
  elif .type == "_exec_error" then
    .message as $message |
    ["exec_error"] +
    (if ($message | test("^provider request limit reached: [0-9]+$")) then
       ($message | capture(": (?<limit>[0-9]+)$").limit) as $limit |
       ["Turn limit reached", "This turn reached the maximum of \($limit) provider requests."]
     elif ($message | test("(^| )hooks?( |$)")) then
       ["Hook failed", $message]
     elif ($message | contains("no API key was supplied")) then
       ["API key required", $message]
     elif ($message | contains("credentials are unavailable; authenticate")) then
       ["Authentication required", $message]
     elif ($message | contains("credentials rejected")) then
       ["Authentication failed", $message]
     elif ($message | contains("request timed out")) then
       ["Request timed out", $message]
     elif ($message | contains("could not resolve the provider host") or
         contains("could not connect to the provider") or contains("TLS connection failed")) then
       ["Provider connection failed", $message]
     elif ($message | test(": HTTP 429(:|$)")) then
       ["Provider rate limit reached", $message]
     elif ($message | test(": HTTP [0-9]{3}(:|$)")) then
       ["Provider request failed", $message]
     elif ($message == "cannot prepare provider request" or
           ($message | contains(": request failed"))) then
       ["Provider request failed", $message]
     elif ($message | contains("invalid canonical request") or
           contains("cannot translate canonical request")) then
       ["Provider request invalid", $message]
     elif ($message == "backend exited before completing a response") then
       ["Provider response incomplete", $message]
     elif ($message == "backend emitted an invalid event stream" or
           ($message | contains("cannot read the response status")) or
           $message == "cannot inspect provider response" or
           ($message | contains("cannot normalize API response"))) then
       ["Provider response invalid", $message]
     elif ($message == "invalid permission response" or
           $message == "cannot prepare permission request") then
       ["Permission failed", $message]
     elif ($message | startswith("session is busy: ")) then
       ["Session busy", $message]
     elif ($message | startswith("session working directory is unavailable: ")) then
       ["Working directory unavailable", $message]
     elif ($message | test("^(cannot (append|create|inspect|prepare|read|release|repair|replace|restore|secure|timestamp|write) session|invalid session path:)")) then
       ["Session failed", $message]
     elif ($message == "sandbox executable is unavailable" or
           ($message | startswith("sandbox executable is unavailable: "))) then
       ["Sandbox unavailable", $message]
     elif ($message == "cannot inspect configured tools" or
           $message == "cannot resolve native temporary directory" or
           $message == "sandbox bypass reason is required" or
           ($message | test("^(cannot (bound|capture|decode|inspect|load|prepare) (denied )?tool|tool (command|process|session)|shell tool execution failed)"))) then
       ["Tool failed", $message]
     elif ($message == "cannot prepare handoff") then
       ["Handoff failed", $message]
     else
       ["Turn failed", $message]
     end)
  elif .type == "_hook_display" then
    ["hook_display", .hook, .script, .text]
  elif .type == "_tool_permission_request" then
    (.tool | tool_permission_display($event_runtime.harness.tools // [])) as $preview |
     ["permission_request", .id, .tool.name,
      (if ($preview.content | length) > 1000
       then $preview.content[0:1000] + "…" else $preview.content end),
      .reason, $preview.format]
  elif .type == "_handoff" and
      (.argv | type == "array" and length > 0 and
       (.[0] | type == "string" and length > 0) and
       all(.[]; type == "string" and (contains("\u0000") | not))) then
    ["handoff", (.argv | tojson)]
  elif .type == "_session_update" and
      (.runtime |
        type == "object" and keys == ["backend", "harness", "profile"] and
        (({type:"session",format_version:1,cwd:"/",created:"1970-01-01T00:00:00Z"} + .) |
          canonical_session_header(1))) then
    ["session_update", (.runtime | tojson)]
  elif canonical_session_header(1) or
      (.type == "system" and canonical_session_record) then
    empty
  elif canonical_user_message or canonical_assistant_message or
      canonical_tool_result or canonical_context then
    durable_display_fields(false; ($event_runtime.harness.tools // []))
  else
    error("unsupported exec event")
  end;

split("\n") | map(select(length > 0) | fromjson) |
reduce .[] as $event (
  {runtime:$runtime, fields:[]};
  .runtime as $event_runtime |
  ([$event | event_fields($event_runtime)]) as $fields |
  .fields += $fields |
  if $event.type == "_session_update" then .runtime = $event.runtime else . end
) |
.fields | emit_display_batch
