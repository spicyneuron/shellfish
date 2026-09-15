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
    # Before-result hook views were transient edits to the live tool block.
    # Only correlated results after their tool result replay as notes.
    (reduce $records[1:][] as $record (
      {calls:{}, records:[]};
      if $record.type == "assistant" then
        .calls = {} | .records += [$record]
      elif $record.type == "tool_result" then
        .calls[$record.call_id] = true | .records += [$record]
      elif $record.type == "hook_result" and $record.tool_use_id? != null and
          (.calls[$record.tool_use_id] // false | not) then .
      else .records += [$record] end
    ).records) as $display_records |
    ["session_update", ($records[0] | {backend, harness, profile} | tojson)],
    ($display_records[] |
      if .type == "tool_result" then
        ({record:.,tools:$tools} | render_tool_before_view) as $before |
        ({record:.,tools:$tools} | render_tool_after_view) as $view |
        ["tool_call", .call_id, $before.text, .name,
          ($before.identity_start | tostring)],
        ["tool_result", .call_id, $view.text, .name, ($view.identity_start | tostring)]
      elif .type == "hook_result" then
        .name as $name | (.user_text // "") as $text |
        ["hook_result", .hook, (.executable // .name), $text,
          (if $text | startswith($name) then "0" else "-1" end),
          (if (.model_text // "") == "" then "0" else "1" end),
          (.tool_use_id // "")]
      else {record:.,replay:true} | durable_display_fields end),
    ([$records[1:][] | select(canonical_assistant_message and has("usage"))] |
      last? | select(. != null) | .usage |
      turn_usage_fields($records[0].profile.context_window // null))
  end
end]
| emit_display_batch
