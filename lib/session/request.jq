def context_message($context; $request):
  ([$context[].model_context | select(length > 0)] | join("\n\n")) as $blocks |
  {type:"user", content:[{type:"text", text:($blocks + "\n\n" + $request)}]};

def request_messages:
  reduce .[] as $record ({messages:[], context:[], pending:null};
    if $record.type == "state" then .
    elif $record.type == "hook_result" then
      if ($record.model_context? // "") != "" then .context += [$record] else . end
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
      if $record.stop == "tool_calls" then .pending = ($record | del(.usage))
      else .pending = null | .messages += [$record | del(.usage)] end
    elif $record.type == "tool_result" then
      if .pending != null then .messages += [.pending] | .pending = null else . end |
      .messages += [
        {type:"tool_call",id:$record.call_id,name:$record.name,input:$record.input},
        $record
      ]
    elif ($record.type | IN("system", "session", "turn_error")) then .
    else error("unrecognized session record: " + ($record.type | tostring)) end
  ) as $conversation |
  if ($conversation.context | length) == 0 then $conversation.messages
  else $conversation.messages + [context_message($conversation.context; "")] end;
