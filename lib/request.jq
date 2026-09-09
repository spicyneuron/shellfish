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

# Calls leave the message: each becomes its own record once it reaches
# execution, so the response yields a message and an ordered call list.
def backend_response_parts(valid_message):
  select(.valid and .ended) |
  . as $state |
  [.blocks | to_entries | sort_by(.key | tonumber)[] | .value |
    if .type != "tool_call" then {valid:true, content:., call:null}
    elif $state.stop == "length" then {valid:true, content:null, call:null}
    elif $state.stop != "tool_calls" then {valid:false, content:null, call:null}
    else (.input_text | if . == "" then {} else try fromjson catch null end) as $input |
      if .id != null and .name != null and ($input | type) == "object" then
        {valid:true, content:null, call:{type, id, name, input:$input}}
      else {valid:false, content:null, call:null} end
    end] as $blocks |
  select(all($blocks[]; .valid)) |
  {message:({type:"message", role:"assistant", stop:$state.stop,
             content:[$blocks[].content | select(. != null)]} +
            (if $state.usage == null then {} else {usage:$state.usage} end)),
   calls:[$blocks[].call | select(. != null)]} |
  select([.calls[].id] | length == (unique | length)) |
  select(.message | valid_message);

def assemble_backend_parts(valid_events; valid_message):
  select(valid_events) |
  reduce .[] as $event
    (backend_response_state; backend_response_update($event)) |
  backend_response_parts(valid_message);

def assemble_backend_response(valid_events; valid_message):
  assemble_backend_parts(valid_events; valid_message) | .message;

# The bypass fields pair with the tool schema injected by libexec/run/tools.zsh.
def tool_call_fields:
  (.id, "\u0000", .name, "\u0000", (.input | tojson), "\u0000",
   (.input | del(.request_sandbox_bypass, .sandbox_bypass_reason) | tojson), "\u0000",
   (.input | if has("request_sandbox_bypass") then
      if (.request_sandbox_bypass | type) == "boolean"
      then (.request_sandbox_bypass | tostring) else "invalid" end
    else "false" end), "\u0000",
   (.input.sandbox_bypass_reason |
    if type == "string" and length > 0 then "true" else "false" end), "\u0000");

def decode_backend_response(valid_event; valid_message):
  foreach inputs as $event
    (backend_response_state + {output:[]};
      .output = [] |
      if .ended or ($event | valid_event | not) then halt_error(1)
      else
        backend_response_update($event) |
        if .valid | not then halt_error(1)
        elif $event.type == "_assistant_end" then
          [backend_response_parts(valid_message)] as $parts |
          if ($parts | length) != 1 then halt_error(1)
          else
            $parts[0].message as $message |
            $parts[0].calls as $calls |
            .output = ["end", "\u0000", ($event | tojson), "\u0000",
              ($message | tojson), "\u0000",
              ($message.stop), "\u0000",
              ($calls | length | tostring), "\u0000",
              ($calls[] | tool_call_fields),
              "ok", "\u0000",
              ([$message.content[] | select(.type == "text") | .text] | join("")), "\u0000"]
          end
        else
          # Every other adapter event passes through unchanged.
          .output = ["event", "\u0000", ($event | tojson), "\u0000"]
        end
      end;
      .output[]);
