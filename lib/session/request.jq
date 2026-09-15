def join_context($parts):
  [$parts[] | select(. != "")] | join("\n\n");

def context_message($entries; $request):
  {type:"user",
   content:[{type:"text", text:join_context([$entries[], $request])}]};

# Every settled result carries its own model text, so this is a forward-only
# reduction: uncorrelated hook context waits for the next message, and a tool
# result reconstructs its call/result pair directly.
def request_messages:
  reduce .[] as $record
    ({messages:[], context:[], pending:null};
    if $record.type == "state" then .
    elif $record.type == "hook_result" then
      if ($record.model_text // "") == "" then .
      else .context += [$record.model_text] end
    elif $record.type == "user" then
      .pending = null |
      if (.context | length) == 0 then .messages += [$record]
      else
        ([$record.content[] | select(.type == "text") | .text] | join("")) as $request |
        .messages += [context_message(.context; $request)] |
        .context = []
      end
    elif $record.type == "assistant" then
      (if (.context | length) > 0 then
        .messages += [context_message(.context; "")] | .context = []
      else . end) |
      if $record.stop == "tool_calls" then .pending = ($record | del(.usage))
      else .pending = null | .messages += [$record | del(.usage)] end
    elif $record.type == "tool_result" then
      (if .pending != null then .messages += [.pending] | .pending = null else . end) |
      .messages += [
        {type:"tool_call",id:$record.id,name:$record.name,input:$record.input},
        {type:"tool_result",call_id:$record.id,name:$record.name,
         exit_code:$record.exit_code,content:($record.model_text // "")}
      ]
    elif ($record.type | IN("system", "session", "error")) then .
    else error("unrecognized session record: " + ($record.type | tostring)) end
  ) as $conversation |
  if ($conversation.context | length) == 0 then $conversation.messages
  else $conversation.messages + [context_message($conversation.context; "")] end;
