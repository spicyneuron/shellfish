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
    .message as $message |
    ["exec_error"] +
    (if ($message | test("^provider request limit reached: [0-9]+$")) then
       ($message | capture(": (?<limit>[0-9]+)$").limit) as $limit |
       ["Turn limit reached", "This turn reached the maximum of \($limit) provider requests."]
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
     elif ($message | startswith("session is busy: ")) then
       ["Session busy", $message]
     elif ($message | startswith("session working directory is unavailable: ")) then
       ["Working directory unavailable", $message]
     elif ($message | test("(^| )hooks?( |$)")) then
       ["Hook failed", $message]
     else
       ["Turn failed", $message]
     end) + ["", "", ""]
  elif .type == "_hook_display" then
    ["hook_display", .event, .hook, .text, "", ""]
  elif .type == "_tool_permission_request" then
    ((if .tool.name == "shell" then [.tool.input.command, "sh"]
      else [(.tool.input | del(.request_sandbox_bypass, .sandbox_bypass_reason) | tojson), "json"]
      end) as [$preview, $language] |
     ["permission_request", .id, .tool.name,
      (if ($preview | length) > 1000 then $preview[0:1000] + "…" else $preview end),
      .reason, $language])
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
