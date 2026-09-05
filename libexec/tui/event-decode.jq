include "lib/runtime/schema";
include "libexec/tui/display-fields";

def event_fields($event_runtime):
  if .type == "_assistant_delta" then
    ["assistant_delta", .text]
  elif .type == "_assistant_reasoning_delta" then
    ["assistant_reasoning_delta", .text]
  elif . == {type:"_backend_request_start"} then
    ["backend_request_start"]
  elif .type == "_turn_usage" then
    turn_usage_fields($event_runtime.profile.context_window // null)
  elif .type == "_turn_error" and (.message | type == "string") then
    ["exec_error", "Turn failed", .message]
  elif .type == "_hook_display" and
      (keys == ["complete", "hook", "script", "text", "type"]) and
      ([.hook, .script, .text] | all(type == "string")) and
      (.complete | type == "boolean") then
    ["hook_display", .hook, .script, .text, (.complete | tostring)]
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
