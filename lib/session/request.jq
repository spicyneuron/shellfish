def join_context($parts):
  [$parts[] | select(. != "")] | join("\n\n");

# Core-owned provenance around script-owned bodies: adjacent entries from one
# hook share a group. Bodies stay verbatim; hook scripts are trusted, and tool
# results carry the same content unescaped.
def context_envelope($entries):
  (reduce $entries[] as $entry ([];
    if length > 0 and .[-1].hook == $entry.hook then .[-1].entries += [$entry]
    else . + [{hook:$entry.hook, entries:[$entry]}] end)) as $groups |
  [$groups[] |
    "<hook name=\"" + .hook + "\">\n" +
    ([.entries[] | "<context script=\"" + .script + "\">" + .body + "</context>"] |
      join("\n")) +
    "\n</hook>"] |
  join("\n\n");

def context_message($entries; $request):
  {type:"user",
   content:[{type:"text", text:join_context([context_envelope($entries), $request])}]};

def hook_entry($record; $body):
  {hook:$record.hook, script:$record.script, body:$body};

# Lifecycle order around the tool's own rendering.
def call_content($call):
  join_context([context_envelope($call.pre // []), $call.body,
    context_envelope($call.post // [])]);

# Hook context correlated to a tool call joins that call's result; uncorrelated
# context waits for the next message. Correlated context with no settled result
# is dropped rather than delivered out of place.
def request_messages:
  reduce .[] as $record
    ({messages:[], context:[], pending:null, calls:{}};
    if $record.type == "state" then .
    elif $record.type == "hook_result" then
      ($record.model_context // "") as $body |
      ($record.tool_use_id // "") as $call_id |
      if $body == "" then .
      elif $call_id == "" then .context += [hook_entry($record; $body)]
      elif .calls[$call_id].index == null then
        .calls[$call_id].pre += [hook_entry($record; $body)]
      else
        .calls[$call_id].post += [hook_entry($record; $body)] |
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
