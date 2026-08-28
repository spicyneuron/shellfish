include "runtime/schema";

def display_nul_safe:
  gsub("\u0000"; "�");

def emit_display_batch:
  (.[], ["batch_ok", "", "", "", "", ""]) |
  if length != 6 or any(.[]; type != "string") then
    error("invalid display fields")
  else .[] | display_nul_safe, "\u0000" end;

def tool_call_display($tools):
  . as $call |
  ($tools | map(select(.name == $call.name))[0].manifest // null) as $manifest |
  if $manifest == null or (($manifest.display.call.content // []) | length) == 0 then
    {content:($call.input | del(.request_sandbox_bypass, .sandbox_bypass_reason) | tojson),
     format:"json"}
  else
    ($manifest.input_schema.properties // {} |
      with_entries(select(.value | has("default")) | .value = .value.default)) as $defaults |
    {content:([$manifest.display.call.content[] |
      if startswith("$") then
        .[1:] as $field |
        (if $call.input | has($field) then $call.input[$field]
         else $defaults[$field] end) |
        if . == null then "" elif type == "string" then . else tojson end
      else . end] | join("")), format:"plain"}
  end;

def durable_display_fields($replay; $tools):
  if .type == "system" and $replay then
    ["system", .content, "", "", "", ""]
  elif canonical_user_message then
    if $replay then ["user", .content[0].text, "", "", "", ""]
    else ["user_commit", "", "", "", "", ""] end
  elif canonical_assistant_message then
    (if $replay then
      ([(.content[] | select(.type == "reasoning") | .text)] | join("\n")) as $reasoning |
      (if .usage | has("reasoning_tokens") then (.usage.reasoning_tokens | tostring) else "" end) as $reasoning_tokens |
      ["assistant", ([.content[] | select(.type == "text") | .text] | join("")),
       $reasoning, $reasoning_tokens, "", ""]
    else empty end),
    ["assistant_commit", "", "", "", "", ""],
    (.content[] | select(.type == "tool_call") | . as $call |
      tool_call_display($tools) as $call_display |
      ["tool_call", .id,
       (.name + (if .input.request_sandbox_bypass? == true
                 then " unsandboxed" else "" end)),
       $call_display.content,
       (($tools | map(select(.name == $call.name))[0].manifest.display.call.always_full // false) |
         if . then "full" else "" end), $call_display.format])
  elif canonical_tool_result then
    . as $result |
    ($tools | map(select(.name == $result.name))[0].manifest.display.result // {}) as $display |
    # An empty status denotes a pending call; hidden denotes a completed call without a footer.
    ["tool_result", .call_id,
      (if ($display.exit_code // false) or .exit_code != 0
       then (.exit_code | tostring) else "hidden" end),
      .content, (.result_type // ""),
      (if ($display.always_full // false) then "full" else "" end)]
  elif canonical_context then
    ["context", .hook,
      ([.tag, .prompt?] |
        map(select(. != null and . != "")) | join(" ")), .content, "", ""]
  else
    empty
  end;
