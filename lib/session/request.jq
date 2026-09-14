def join_context($parts):
  [$parts[] | select(. != "")] | join("\n\n");

def context_message($context; $request):
  {type:"user", content:[{type:"text", text:(join_context($context) + "\n\n" + $request)}]};

# Hook context correlated to a tool call joins that call's result; uncorrelated
# context waits for the next message. Correlated context with no settled result
# is dropped rather than delivered out of place.
def request_messages:
  reduce .[] as $record
    ({messages:[], context:[], pending:null, tool_context:{}, tool_index:{}};
    if $record.type == "state" then .
    elif $record.type == "hook_result" then
      ($record.model_context // "") as $context |
      ($record.tool_use_id // "") as $call_id |
      if $context == "" then .
      elif $call_id == "" then .context += [$context]
      elif .tool_index[$call_id] != null then
        .messages[.tool_index[$call_id]].content |= join_context([., $context])
      else .tool_context[$call_id] += [$context] end
    elif $record.type == "user" then
      .pending = null |
      if (.context | length) == 0 then .messages += [$record]
      else
        ([$record.content[] | select(.type == "text") | .text] | join("")) as $request |
        .messages += [context_message(.context; $request)] |
        .context = []
      end
    elif $record.type == "assistant" then
      if (.context | length) > 0 then
        .messages += [context_message(.context; "")] | .context = []
      else . end |
      # Call IDs are unique only within one response.
      .tool_context = {} | .tool_index = {} |
      if $record.stop == "tool_calls" then .pending = ($record | del(.usage))
      else .pending = null | .messages += [$record | del(.usage)] end
    elif $record.type == "tool_result" then
      if .pending != null then .messages += [.pending] | .pending = null else . end |
      ((.tool_context[$record.call_id] // []) + [$record.content]) as $content |
      .tool_index[$record.call_id] = (.messages | length) + 1 |
      .messages += [
        {type:"tool_call",id:$record.call_id,name:$record.name,input:$record.input},
        ($record | del(.input, .stdout, .stderr) | .content = join_context($content))
      ]
    elif ($record.type | IN("system", "session", "turn_error")) then .
    else error("unrecognized session record: " + ($record.type | tostring)) end
  ) as $conversation |
  if ($conversation.context | length) == 0 then $conversation.messages
  else $conversation.messages + [context_message($conversation.context; "")] end;
