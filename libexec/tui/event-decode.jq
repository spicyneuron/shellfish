include "lib/runtime/schema";
include "lib/session/read";
include "libexec/tui/display-fields";

def event_fields:
  .runtime as $event_runtime |
  .event |
  if .type == "_assistant_message_delta" and canonical_backend_event then
    ["assistant_message_delta", (.index | tostring), .text]
  elif .type == "_assistant_reasoning_delta" and canonical_backend_event then
    ["assistant_reasoning_delta", (.index | tostring), .text]
  elif .type == "_assistant_tool_call_delta" and canonical_backend_event then
    ["assistant_tool_call_delta", (.index | tostring)]
  elif .type == "_assistant_reasoning_opaque" and canonical_backend_event then
    ["assistant_reasoning_opaque", (.index | tostring)]
  elif .type == "_turn_usage" and canonical_backend_event then
    empty
  elif .type == "_hook_activity" and
      ((keys - ["executable", "hook", "id", "input", "name", "type", "user_text"]) |
        length == 0) and
      (["hook", "id", "input", "name", "type"] - keys | length == 0) and
      (.hook as $hook | hook_names | index($hook) != null) and
      (.id | identifier) and (.name | type == "string" and length > 0) and
      (.input | type == "string" or type == "object") then
    if (.user_text // "") == "" then empty
    else ["hook_call", .id, .user_text, .name, "notice"] end
  elif . == {type:"_assistant_start"} then
    ["assistant_start"]
  elif .type == "_assistant_end" and keys == ["stop", "type"] and
      (.stop | IN("end", "tool_calls", "length")) then
    ["assistant_end"]
  elif .type == "_session_prepare" and
      keys == ["path", "records", "type"] and
      (.path | nul_free_string and startswith("/")) and
      (.records | type == "array" and (length == 1 or length == 2) and
        (.[0] | canonical_session_header(1)) and
        all(.[1:][]; canonical_system)) then
    ["session_prepare", (.records[0] | {backend,harness,profile} | tojson),
     (.records[1].content // "")]
  elif .type == "_session_created" and keys == ["path", "type"] and
      (.path | nul_free_string and startswith("/")) then
    ["session_created", .path]
  elif .type == "_tool_permission_request" then
    (.preview // "") as $preview |
     ["permission_request", .id, .tool.name,
      (if ($preview | length) > 1000
       then $preview[0:1000] + "…" else $preview end),
      .reason, "plain"]
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
  elif canonical_session_header(1) or canonical_state or canonical_system then
    empty
  elif canonical_tool_activity then
    ["tool_call", .id, (.user_text // ""), .name, "tool"]
  elif canonical_tool_result then
    ["tool_result", .id, (.user_text // ""), .name, "tool"]
  elif canonical_hook_result then
    ["hook_result", .id, (.user_text // ""), .name, hook_display_class]
  elif canonical_user_message or canonical_response or canonical_error then
    (select(canonical_response and has("usage")) | .usage |
      turn_usage_fields($event_runtime.profile.context_window // null)),
    ({record:.,replay:false} | durable_display_fields)
  else
    error("unsupported exec event")
  end;

split("\n") | map(select(length > 0) | fromjson) |
reduce .[] as $event (
  {runtime:$runtime, fields:[]};
  .runtime as $event_runtime |
  ([{event:$event,runtime:$event_runtime} | event_fields]) as $fields |
  .fields += $fields |
  if $event.type == "_session_update" then .runtime = $event.runtime
  elif $event.type == "_session_prepare" then .runtime = $event.records[0]
  else . end
) |
.fields | emit_display_batch
