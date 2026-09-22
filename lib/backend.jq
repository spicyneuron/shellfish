# Adapter request and event protocol.
#
# Repeated primitives are deliberate; see AGENTS.md.

def identifier: type == "string" and test("^[A-Za-z0-9_-]+$");
def tool_name: type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");
def token_count:
  type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
def content_index:
  type == "number" and floor == . and . >= 0 and . <= 2147483647;

def token_usage:
  type == "object" and
  ((keys - ["input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens"]) |
    length == 0) and
  (.input_tokens | token_count) and (.output_tokens | token_count) and
  (if has("cached_tokens") then
     (.cached_tokens | token_count) and .cached_tokens <= .input_tokens
   else true end) and
  (if has("reasoning_tokens") then .reasoning_tokens | token_count else true end);

def canonical_backend_event:
  type == "object" and
  if .type == "_assistant_message_delta" or .type == "_assistant_reasoning_delta" then
    keys == ["index", "text", "type"] and (.index | content_index) and
    (.text | type == "string")
  elif .type == "_assistant_reasoning_opaque" then
    keys == ["index", "opaque", "type"] and (.index | content_index) and
    (.opaque | type == "object")
  elif .type == "_assistant_tool_call_delta" then
    ((keys - ["id", "index", "input", "name", "type"]) | length == 0) and
    (["index", "type"] - keys | length == 0) and
    (has("id") or has("name") or has("input")) and
    (.index | content_index) and
    (if has("id") then .id | identifier else true end) and
    (if has("name") then .name | tool_name else true end) and
    (if has("input") then .input | type == "string" else true end)
  elif .type == "_turn_usage" then
    del(.type) | token_usage
  elif .type == "_assistant_end" then
    keys == ["stop", "type"] and (.stop | IN("end", "tool_calls", "length"))
  else false end;

def canonical_backend_response_events:
  type == "array" and length > 0 and all(.[]; canonical_backend_event) and
  .[-1].type == "_assistant_end" and
  ([.[] | select(.type == "_assistant_end")] | length) == 1;

def backend_adapter_request($runtime; $system; $messages; $tools):
  {
    format_version:1,
    system:$system,
    messages:$messages,
    tools:$tools,
    options:{request:$runtime.profile.request},
    transport:($runtime.backend | {endpoint,insecure_tls,http_timeout,http_stall})
  } | select(all(.messages[] | select(.type == "user");
    .content[0].text | index("\u0000") | not));

def backend_response_state:
  {blocks:{}, usage:null, stop:null, valid:true, ended:false};

def backend_response_update($event):
  ($event.index? | tostring) as $index |
  if (.valid | not) or .ended then .valid = false
  elif $event.type == "_assistant_message_delta" then
    if .blocks[$index] == null then
      .blocks[$index] = {type:"text", text:$event.text}
    elif .blocks[$index].type == "text" then
      .blocks[$index].text += $event.text
    else .valid = false end
  elif $event.type == "_assistant_reasoning_delta" then
    if .blocks[$index] == null then
      .blocks[$index] = {type:"reasoning", text:$event.text}
    elif .blocks[$index].type == "reasoning" then
      .blocks[$index].text += $event.text
    else .valid = false end
  elif $event.type == "_assistant_reasoning_opaque" then
    if .blocks[$index] == null then
      .blocks[$index] = {type:"reasoning", text:"", opaque:$event.opaque}
    elif .blocks[$index].type != "reasoning" then .valid = false
    elif .blocks[$index].opaque != null and .blocks[$index].opaque != $event.opaque then
      .valid = false
    else .blocks[$index].opaque = $event.opaque end
  elif $event.type == "_assistant_tool_call_delta" then
    if .blocks[$index] == null then
      .blocks[$index] = {type:"tool_call", id:null, name:null, input_text:""}
    else . end |
    if .blocks[$index].type != "tool_call" then .valid = false
    elif ($event.id? != null and .blocks[$index].id != null and
          .blocks[$index].id != $event.id) or
         ($event.name? != null and .blocks[$index].name != null and
          .blocks[$index].name != $event.name) then .valid = false
    else
      .blocks[$index].id = ($event.id? // .blocks[$index].id) |
      .blocks[$index].name = ($event.name? // .blocks[$index].name) |
      .blocks[$index].input_text += ($event.input? // "")
    end
  elif $event.type == "_turn_usage" then .usage = ($event | del(.type))
  elif $event.type == "_assistant_end" then
    .stop = $event.stop | .ended = true
  else .valid = false end;

# One complete response: ordered content with inert tool calls.
def backend_response_record(valid_message):
  select(.valid and .ended) |
  . as $state |
  [.blocks | to_entries | sort_by(.key | tonumber)[] | .value |
    if .type != "tool_call" then {valid:true, entry:.}
    elif $state.stop == "length" then {valid:true, entry:null}
    elif $state.stop != "tool_calls" then {valid:false, entry:null}
    else (.input_text | if . == "" then {} else try fromjson catch null end) as $input |
      if .id != null and .name != null and ($input | type) == "object" then
        {valid:true, entry:{type, id, name, input:$input}}
      else {valid:false, entry:null} end
    end] as $blocks |
  select(all($blocks[]; .valid)) |
  ({type:"assistant", stop:$state.stop,
    content:[$blocks[].entry | select(. != null)]} +
   (if $state.usage == null then {} else {usage:$state.usage} end)) |
  select(valid_message);

def assemble_backend_response(valid_events; valid_message):
  select(valid_events) |
  reduce .[] as $event
    (backend_response_state; backend_response_update($event)) |
  backend_response_record(valid_message);

def decode_backend_response(valid_event; valid_message):
  foreach inputs as $event
    (backend_response_state + {output:[]};
      .output = [] |
      if .ended or ($event | valid_event | not) then halt_error(1)
      else
        backend_response_update($event) |
        if .valid | not then halt_error(1)
        elif $event.type == "_assistant_end" then
          [backend_response_record(valid_message)] as $records |
          if ($records | length) != 1 then halt_error(1)
          else
            $records[0] as $message |
            .output = ["end", "\u0000", ($event | tojson), "\u0000",
              ($message | tojson), "\u0000"]
          end
        else
          .output = ["event", "\u0000", ($event | tojson), "\u0000"]
        end
      end;
      .output[]);
