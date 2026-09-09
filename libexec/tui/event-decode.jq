include "lib/runtime/schema";
include "libexec/tui/display-fields";

def event_fields($event_runtime):
  if .type == "_assistant_message_delta" then
    ["assistant_message_delta", .text]
  elif .type == "_assistant_reasoning_delta" then
    ["assistant_reasoning_delta", .text]
  elif .type == "_assistant_tool_call_delta" then
    ["assistant_tool_call_delta"]
  elif .type == "_assistant_reasoning_opaque" or .type == "_turn_usage" then
    # Nothing to present: the durable assistant record carries both.
    empty
  elif . == {type:"_assistant_start"} then
    ["assistant_start"]
  elif .type == "_assistant_end" and keys == ["stop", "type"] and
      (.stop | IN("end", "tool_calls", "length")) then
    ["assistant_end"]
  elif .type == "_notice" and
      keys == ["complete", "level", "source", "text", "title", "type"] and
      ([.title, .source, .text] | all(type == "string")) and
      (.level | IN("info", "error")) and (.complete | type == "boolean") then
    ["notice", (if .level == "error" then "error" else "notice" end),
     (.title | sub("/run$"; "") | split("/") | last), .source, .text,
     (if .complete then "closed" else "open" end)]
  elif .type == "_session_prepare" and
      keys == ["path", "records", "type"] and
      (.path | nul_free_string and startswith("/")) and
      (.records | type == "array" and (length == 1 or length == 2) and
        (.[0] | canonical_session_header(1)) and
        all(.[1:][]; .type == "system" and canonical_session_record)) then
    ["session_prepare", (.records[0] | {backend,harness,profile} | tojson),
     (.records[1].content // "")]
  elif .type == "_session_created" and keys == ["path", "type"] and
      (.path | nul_free_string and startswith("/")) then
    ["session_created", .path]
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
  elif canonical_session_header(1) or canonical_state or
      (.type == "system" and canonical_session_record) then
    empty
  elif canonical_user_message or canonical_assistant_message or
      canonical_tool_result or canonical_context or
      (.type == "turn_error" and canonical_session_record) then
    # Usage is committed with its assistant record rather than streamed.
    (select(canonical_assistant_message and has("usage")) | .usage |
      turn_usage_fields($event_runtime.profile.context_window // null)),
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
  if $event.type == "_session_update" then .runtime = $event.runtime
  elif $event.type == "_session_prepare" then .runtime = $event.records[0]
  else . end
) |
.fields | emit_display_batch
