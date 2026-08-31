def xml_escape:
  gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") |
  gsub("\""; "&quot;");

# Schema-constrained tags and XML-escaped text prevent forged blocks.
def context_item:
  "<context script=\"" + (.script | xml_escape) + "\"" +
  (if has("prompt") then " prompt=\"" + (.prompt | xml_escape) + "\"" else "" end) +
  (if has("status") then " status=\"" + (.status | tostring) + "\"" else "" end) +
  ">\n" + (.content | xml_escape) + "\n</context>";

def context_groups:
  reduce .[] as $record ([];
    if length > 0 and .[-1][0].hook == $record.hook then
      .[-1] += [$record]
    else . += [[$record]] end);

def context_group:
  .[0].hook as $hook |
  "<hook name=\"" + $hook + "\">\n" + ([.[] | context_item] | join("\n\n")) +
  "\n</hook>";

def context_message($context; $request):
  ([$context | context_groups[] | context_group] | join("\n\n")) as $blocks |
  {role:"user", content:[{type:"text", text:($blocks + "\n\n" + $request)}]};

# Fold roleless context into the next message, or a trailing user message.
def request_messages:
  reduce .[] as $record ({messages:[], context:[]};
    if $record.type == "context" then .context += [$record]
    elif $record.type == "message" and $record.role == "user" then
      if (.context | length) == 0 then .messages += [$record | del(.type, .usage)]
      else
        ([$record.content[] | select(.type == "text") | .text] | join("")) as $request |
        .messages += [context_message(.context; $request)] |
        .context = []
      end
    elif $record.type == "message" then
      # Only assistant context stands alone; tool results must stay paired.
      if $record.role == "assistant" and (.context | length) > 0 then
        .messages += [context_message(.context; ""), ($record | del(.type, .usage))] |
        .context = []
      else .messages += [$record |
        if .role == "tool_result" and .sandbox_denial_detected? == true then
          .content += (if .content == "" then "" else "\n\n" end) +
            "Sandbox notice: A sandbox denial was detected while this tool was running."
        else . end |
        del(.type, .usage, .sandbox_denial_detected, .sandboxed)] end
    elif ($record.type | IN("system", "session")) then .
    else error("unrecognized session record: " + ($record.type | tostring)) end
  ) as $conversation |
  if ($conversation.context | length) == 0 then $conversation.messages
  else $conversation.messages + [context_message($conversation.context; "")] end;
