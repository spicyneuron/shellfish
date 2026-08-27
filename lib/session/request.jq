def xml_escape:
  gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") |
  gsub("\""; "&quot;");

# Schema-constrained tags and XML-escaped text prevent forged blocks.
def context_block:
  "<" + .tag + " hook=\"" + (.hook | xml_escape) + "\"" +
  (if has("prompt") then " prompt=\"" + (.prompt | xml_escape) + "\"" else "" end) +
  (if has("status") then " status=\"" + (.status | tostring) + "\"" else "" end) +
  ">\n" + (.content | xml_escape) + "\n</" + .tag + ">";

def context_message($context; $request):
  ([$context[] | context_block] | join("\n\n")) as $blocks |
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
      else .messages += [$record | del(.type, .usage, .result_type, .sandboxed)] end
    elif ($record.type | IN("system", "session")) then .
    else error("unrecognized session record: " + ($record.type | tostring)) end
  ) as $conversation |
  if ($conversation.context | length) == 0 then $conversation.messages
  else $conversation.messages + [context_message($conversation.context; "")] end;
