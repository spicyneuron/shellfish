include "runtime/schema";

def display_nul_safe:
  gsub("\u0000"; "�");

# Each event is a leading type and up to six fields, padded to a fixed width so
# readers can take them in fixed-size groups.
def emit_display_batch:
  (.[], ["batch_ok"]) |
  if length < 1 or length > 7 or any(.[]; type != "string") then
    error("invalid display fields")
  else (. + ["", "", "", "", "", ""])[0:7][] | display_nul_safe, "\u0000" end;

def tool_input_display($call; $content):
  [$content[] |
    if startswith("$") then
      .[1:] as $field |
      if $field == "input_json" then
        ($call.input | del(.request_sandbox_bypass, .sandbox_bypass_reason) | tojson)
      elif $call.input | has($field) then
        $call.input[$field] |
        if . == null then "" elif type == "string" then . else tojson end
      else ""
      end
    else . end] | join("");

def tool_call_display($tools):
  . as $call |
  ($tools | map(select(.name == $call.name))[0].manifest // null) as $manifest |
  ($manifest.display.summary // []) as $summary |
  ($manifest.display.call // ["$input_json"]) as $content |
  {summary:(tool_input_display($call; $summary) |
      gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "")),
   content:tool_input_display($call; $content),
   format:(if $content == ["$input_json"] then "json" else "plain" end)};

def durable_display_fields($replay; $tools):
  if .type == "system" and $replay then
    ["system", .content]
  elif canonical_user_message then
    if $replay then ["user", .content[0].text] else empty end
  elif canonical_assistant_message then
    (if $replay then
      ([(.content[] | select(.type == "reasoning") | .text)] | join("\n")) as $reasoning |
      (if .usage | has("reasoning_tokens") then (.usage.reasoning_tokens | tostring) else "" end) as $reasoning_tokens |
      ["assistant", ([.content[] | select(.type == "text") | .text] | join("")),
       $reasoning, $reasoning_tokens]
    else empty end),
    ["assistant_commit"],
    (.content[] | select(.type == "tool_call") | . as $call |
      tool_call_display($tools) as $call_display |
      ["tool_call", .id,
       (.name + (if $call_display.summary == "" then ""
                 else " · " + $call_display.summary end) +
        (if .input.request_sandbox_bypass? == true then " · unsandboxed" else "" end)),
       $call_display.content,
       "", $call_display.format])
  elif canonical_tool_result then
    . as $result |
    ($tools | map(select(.name == $result.name))[0].manifest.display.result //
      ["$result_preview"]) as $display |
    # An empty status denotes a pending call; hidden denotes a completed call without a footer.
    ["tool_result", .call_id,
      (if ($display | index("$exit_code")) != null or .exit_code != 0
       then (.exit_code | tostring) else "hidden" end),
      (if any($display[]; . == "$result_preview" or . == "$result_full")
       then .content else "" end), (.result_type // ""),
      (if ($display | index("$result_full")) != null then "full" else "" end),
      (if .sandbox_blocked? == true then "blocked" else "" end)]
  elif canonical_context then
    ["context", .hook,
      ([.tag, .prompt?] |
        map(select(. != null and . != "")) | join(" ")), .content]
  else
    empty
  end;
