include "lib/runtime/schema";
include "lib/session/read";
include "libexec/tui/display-fields";

def durable_prefix:
  if endswith("\n") then
    .
  else
    rindex("\n") as $end |
    if $end == null then error("incomplete session header")
    else .[0:($end + 1)]
    end
  end;

[. as $raw |
if $raw == "" then
  empty
else
  ($raw | durable_prefix | split("\n") |
    map(select(length > 0) | fromjson)) as $records |
  if ($records | length) < 1 or
      ($records[0] | canonical_session_header(1) | not)
  then
    error("invalid session")
  else
    ($records[1:] | session_load) as $durable |
    ["session_update", ($records[0] | {backend, harness, profile} | tojson)],
    ($records[1:][] |
      if .type == "tool_result" then
        ["tool_result", .id, (.user_text // ""), .name, "tool"]
      elif .type == "hook_result" then
        ["hook_result", .id, (.user_text // ""), .name, hook_display_class]
      else {record:.,replay:true} | durable_display_fields end),
    ([$records[1:][] | select(.type == "assistant" and has("usage"))] |
      last? | select(. != null) | .usage |
      turn_usage_fields($records[0].profile.context_window // null))
  end
end]
| emit_display_batch
