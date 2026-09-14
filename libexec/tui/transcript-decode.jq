include "lib/runtime/schema";
include "lib/render";
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
      ($records[0] | canonical_session_header(1) | not) or
      ($records[1:] | canonical_session_records | not)
  then
    error("invalid session")
  else
    $records[0].harness.tools as $tools |
    ["session_update", ($records[0] | {backend, harness, profile} | tojson)],
    ($records[1:][] |
      if .type == "tool_call" then
        ({record:.,tools:$tools} | render_tool_before_view) as $view |
        ["tool_call", .id, $view.text, .name, ($view.identity_start | tostring)]
      elif .type == "tool_result" then
        ({record:.,tools:$tools} | render_tool_after_view) as $view |
        ["tool_result", .call_id, $view.text, .name, ($view.identity_start | tostring)]
      else {record:.,replay:true} | durable_display_fields end),
    ([$records[1:][] | select(canonical_assistant_message and has("usage"))] |
      last? | select(. != null) | .usage |
      turn_usage_fields($records[0].profile.context_window // null))
  end
end]
| emit_display_batch
