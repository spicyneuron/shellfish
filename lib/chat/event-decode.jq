include "runtime/schema";
include "chat/display-fields";

def event_fields:
  if .type == "_assistant_delta" then
    ["assistant_delta", .text, "", "", "", ""]
  elif .type == "_assistant_reasoning_delta" then
    ["assistant_reasoning_delta", .text, "", "", "", ""]
  elif . == {type:"_backend_request_start"} then
    ["backend_request_start", "", "", "", "", ""]
  elif .type == "_turn_usage" then
    ["turn_usage",
     ((.input_tokens | tostring) + " ↑" +
       (if has("cached_tokens") and .input_tokens > 0 then
          " " + ((.cached_tokens * 100 / .input_tokens) | floor | tostring) + "% ⦿"
        else "" end) + " " + (.output_tokens | tostring) + " ↓"),
     (if has("reasoning_tokens") then (.reasoning_tokens | tostring) else "" end), "", "", ""]
  elif .type == "_exec_error" then
    ["exec_error", .message, "", "", "", ""]
  elif .type == "_hook_display" then
    ["hook_display", .event, .hook, .text, "", ""]
  elif .type == "_tool_permission_request" then
    ((if .tool.name == "shell" then .tool.input.command
      else (.tool.input | del(.request_sandbox_bypass, .sandbox_bypass_reason) | tojson)
      end) as $preview |
     ["permission_request", .id, .tool.name,
      (if ($preview | length) > 1000 then $preview[0:1000] + "…" else $preview end),
      .reason, (if .tool.name == "shell" then "sh" else "json" end)])
  elif .type == "_handoff" and
      (.argv | type == "array" and length > 0 and
       (.[0] | type == "string" and length > 0) and
       all(.[]; type == "string" and (contains("\u0000") | not))) then
    ["handoff", (.argv | tojson), "", "", "", ""]
  elif canonical_session_header(1) or
      (.type == "system" and canonical_session_record) then
    empty
  elif canonical_user_message or canonical_assistant_message or
      canonical_tool_result or canonical_context then
    durable_display_fields(false; ($runtime.harness.tools // []))
  else
    error("unsupported exec event")
  end;

[split("\n") | map(select(length > 0) | fromjson) | .[] | event_fields]
| emit_display_batch
