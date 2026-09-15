include "lib/runtime/schema";
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
    # Before-result hook views were transient edits to the live tool block.
    # Only correlated results after their tool result replay as notes.
    ["session_update", ($records[0] | {backend, harness, profile} | tojson)],
    ($records[1:][] |
      if .type == "tool_result" then
        ["tool_result", .id, (.user_text // ""), .name, execution_offset]
      elif .type == "hook_result" then
        ["hook_result", .hook, (.executable // .name), (.user_text // ""),
          execution_offset, (if (.model_text // "") == "" then "0" else "1" end)]
      else {record:.,replay:true} | durable_display_fields end),
    ([$records[1:][] | select(canonical_assistant_message and has("usage"))] |
      last? | select(. != null) | .usage |
      turn_usage_fields($records[0].profile.context_window // null))
  end
end]
| emit_display_batch
