# Durable record validity and transcript order. Records are read left to right;
# each view projects the state this reduction reaches.
#
# jq resolves an included module's internal calls only one level deep, so every
# module states its own vocabulary. lib/runtime.jq repeats these primitives and
# owns the header, which validates the runtime nested inside it.

def nul_free_string: type == "string" and (index("\u0000") | not);
def identifier: type == "string" and test("^[A-Za-z0-9_-]+$");
def tool_name: type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");
def token_count:
  type == "number" and floor == . and . >= 0 and . <= 9007199254740991;

def token_usage:
  type == "object" and
  ((keys - ["input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens"]) |
    length == 0) and
  (.input_tokens | token_count) and (.output_tokens | token_count) and
  (if has("cached_tokens") then
     (.cached_tokens | token_count) and .cached_tokens <= .input_tokens
   else true end) and
  (if has("reasoning_tokens") then .reasoning_tokens | token_count else true end);

def record_lifecycle:
  IN("session_start", "user_prompt_submit", "permission_request", "pre_tool_use",
    "post_tool_use", "stop");

def canonical_text:
  type == "object" and keys == ["text", "type"] and
  .type == "text" and (.text | type == "string");

def canonical_reasoning:
  type == "object" and
  (keys == ["text", "type"] or keys == ["opaque", "text", "type"]) and
  .type == "reasoning" and (.text | type == "string") and
  ((has("opaque") | not) or (.opaque | type == "object"));

def canonical_tool_call:
  type == "object" and keys == ["id", "input", "name", "type"] and
  .type == "tool_call" and (.id | identifier) and (.name | tool_name) and
  (.input | type == "object");

def canonical_user_message:
  type == "object" and keys == ["content", "type"] and .type == "user" and
  (.content | type == "array" and length == 1 and (.[0] | canonical_text)) and
  (.content[0].text | nul_free_string);

def canonical_state:
  type == "object" and keys == ["name", "type", "value"] and .type == "state" and
  (.name | type == "string" and length <= 128 and
    test("^[A-Za-z0-9][A-Za-z0-9_.:/-]*\\z"));

def canonical_system:
  type == "object" and keys == ["content", "type"] and .type == "system" and
  (.content | nul_free_string);

def canonical_error:
  type == "object" and keys == ["type", "user_text"] and .type == "error" and
  (.user_text | nul_free_string) and .user_text != "";

# Hook and tool results share one settled base; only identity and input differ.
def canonical_execution_result($extra):
  type == "object" and
  ((keys - (["exit_code", "id", "input", "model_text", "name",
    "type", "user_text"] + $extra)) | length == 0) and
  ((["exit_code", "id", "input", "name", "type"] - keys) | length == 0) and
  (.id | identifier) and
  (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255) and
  (if has("user_text") then .user_text | type == "string" and length > 0 else true end) and
  (if has("model_text") then .model_text | type == "string" and length > 0 else true end);

def canonical_tool_result:
  canonical_execution_result([]) and .type == "tool_result" and
  (.name | tool_name) and (.input | type == "object");

def canonical_hook_result:
  canonical_execution_result(["lifecycle"]) and .type == "hook_result" and
  (.lifecycle | record_lifecycle) and
  (.id | test("^[1-9][0-9]*$")) and
  (.name | nul_free_string and length > 0) and
  (.input | type == "string" or type == "object");

def response_calls: [.content[] | select(.type == "tool_call")];

# One complete provider response. Only a tool-calling stop carries calls.
def canonical_response:
  type == "object" and .type == "assistant" and
  ((keys - ["content", "stop", "type", "usage"]) | length == 0) and
  ((["content", "stop", "type"] - keys) | length == 0) and
  (.stop | IN("end", "tool_calls", "length", "cancelled")) and
  ((has("usage") | not) or (.usage | token_usage)) and
  (.content | type == "array" and
    all(.[]; canonical_text or canonical_reasoning or canonical_tool_call)) and
  (response_calls as $calls |
    if .stop == "tool_calls" then
      ($calls | length) > 0 and (([$calls[].id] | unique | length) == ($calls | length))
    else ($calls | length) == 0 end);

def render_context:
  if type == "string" then .
  else
    "<hook name=\"" + (.lifecycle | @html) + "\">\n" +
    ([.scripts[] |
      "<context script=\"" + (.name | @html) + "\">\n" + .text +
      (if .text | endswith("\n") then "" else "\n" end) + "</context>"] |
      join("\n")) +
    "\n</hook>"
  end;

def add_hook_context($record):
  ([to_entries[] | select(.value.lifecycle? == $record.lifecycle) | .key] | first) as $index |
  {name:$record.name,text:$record.model_text} as $script |
  if $index == null then . + [{lifecycle:$record.lifecycle,scripts:[$script]}]
  else .[$index].scripts += [$script] end;

def join_context($parts):
  [$parts[] | select(. != "") | render_context] | join("\n\n");

def context_message($context; $request):
  {type:"user", content:[{type:"text", text:join_context([$context[], $request])}]};

def session_state:
  reduce .[] as $record
    ({next:"user", calls:[], context:[], hooks:[], messages:[], response:null};
      if ($record | canonical_state) then .
      elif ($record | canonical_system) then
        if .next == "user" then . else error("system text inside a turn") end
      elif ($record | canonical_hook_result) then
        if (.hooks | index($record.id)) != null then
          error("repeated hook id: " + $record.id)
        else
          .hooks += [$record.id] |
          (if ($record.model_text // "") == "" then .
           else .context |= add_hook_context($record) end) |
          # Failing stop feedback continues the turn with another request.
          if $record.lifecycle == "stop" and $record.exit_code != 0 and
              ($record.model_text // "") != "" and .next == "user"
          then .next = "assistant" else . end
        end
      elif ($record | canonical_error) then
        .next = "user" | .calls = [] | .response = null
      elif ($record | canonical_user_message) then
        if .next != "user" then error("user request inside a turn") else . end |
        .messages += [context_message(.context; $record.content[0].text)] |
        .context = [] | .next = "assistant"
      elif ($record | canonical_response) then
        if .next != "assistant" then error("response outside a turn") else . end |
        (if (.context | length) == 0 then .
         else .messages += [context_message(.context; "")] | .context = [] end) |
        ($record | response_calls) as $calls |
        if ($calls | length) == 0 then
          .messages += [$record | del(.usage)] | .next = "user"
        else .calls = $calls | .response = $record | .next = "tool_result" end
      elif ($record | canonical_tool_result) then
        (if (.calls | length) == 0 then error("tool result without a call")
         else .calls[0] end) as $call |
        if $call.id != $record.id or $call.name != $record.name or
            $call.input != $record.input then
          error("tool result does not settle its call: " + $record.id)
        else . end |
        (if .response == null then .
         else
           .messages += [.response | del(.usage) |
             .content = [.content[] | select(.type != "tool_call")]] |
           .response = null
         end) |
        .messages += [{type:"tool_call", id:$call.id, name:$call.name, input:$call.input},
          {type:"tool_result", call_id:$call.id, name:$call.name,
           exit_code:$record.exit_code,
           content:join_context([.context[], ($record.model_text // "")])}] |
        .context = [] |
        .calls = .calls[1:] |
        .next = (if (.calls | length) == 0 then "assistant" else "tool_result" end)
      else error("unrecognized session record") end);

def session_run:
  session_state |
  {next, calls:[.calls[] | {id, name, input}], context:[.context[] | render_context]};

# A response awaiting results reaches no request, and trailing context waits
# here for the request that carries it.
def session_messages:
  session_state |
  if (.context | length) == 0 then .messages
  else .messages + [context_message(.context; "")] end;
