def join_context($parts):
  [$parts[] | select(. != "")] | join("\n\n");

def context_message($entries; $request):
  {type:"user",
   content:[{type:"text", text:join_context([$entries[], $request])}]};

# Lifecycle order around the tool's own rendering.
def call_content($call):
  join_context([($call.pre // [])[], $call.body, ($call.post // [])[]]);

# Hook context correlated to a tool call joins that call's result; uncorrelated
# context waits for the next message. Correlated context with no settled result
# is dropped rather than delivered out of place.
def request_messages:
  reduce .[] as $record
    ({messages:[], context:[], pending:null, calls:{}};
    if $record.type == "state" then .
    elif $record.type == "hook_result" then
      ($record.model_text // "") as $body |
      ($record.tool_use_id // "") as $call_id |
      if $body == "" then .
      elif $call_id == "" then .context += [$body]
      elif .calls[$call_id].index == null then
        .calls[$call_id].pre += [$body]
      else
        .calls[$call_id].post += [$body] |
        .messages[.calls[$call_id].index].content = call_content(.calls[$call_id])
      end
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
      .calls = {} |
      if $record.stop == "tool_calls" then .pending = ($record | del(.usage))
      else .pending = null | .messages += [$record | del(.usage)] end
    elif $record.type == "tool_result" then
      if .pending != null then .messages += [.pending] | .pending = null else . end |
      .calls[$record.call_id].body = $record.content |
      .calls[$record.call_id].index = (.messages | length) + 1 |
      call_content(.calls[$record.call_id]) as $content |
      .messages += [
        {type:"tool_call",id:$record.call_id,name:$record.name,input:$record.input},
        ($record | del(.input, .stdout, .stderr) | .content = $content)
      ]
    elif ($record.type | IN("system", "session", "error")) then .
    else error("unrecognized session record: " + ($record.type | tostring)) end
  ) as $conversation |
  if ($conversation.context | length) == 0 then $conversation.messages
  else $conversation.messages + [context_message($conversation.context; "")] end;
