# Adapter request and response protocol.

def backend_adapter_request($model; $system; $messages; $tools):
  {
    format_version:1,
    system:$system,
    messages:$messages,
    tools:$tools,
    request:$model.request,
    endpoint:$model.endpoint
  } + (if $model | has("config") then {config:$model.config} else {} end) |
  select(all(.messages[] | select(.type == "user");
    .content[0].text | index("\u0000") | not));

# Streamed text or reasoning. Deltas concatenate to the response's own text.
def backend_delta:
  type == "object" and keys == ["text", "type"] and
  (.type == "_assistant_message_delta" or .type == "_assistant_reasoning_delta") and
  (.text | type == "string");

# Deltas pass through until one complete response ends the stream. Anything
# else, including a line after the response, is invalid.
def decode_backend_response(valid_response):
  foreach inputs as $line ({ended:false, out:[]};
    if .ended then halt_error(1)
    elif $line | backend_delta then .out = ["event", "\u0000", ($line | tojson), "\u0000"]
    elif $line | type == "object" and .stop != "cancelled" and valid_response then
      .ended = true | .out = ["end", "\u0000", ($line | tojson), "\u0000"]
    else halt_error(1) end;
    .out[]);

# Deltas joined into the response they were streaming, for a cancelled request.
def backend_delta_response:
  reduce .[] as $delta ([];
    (if $delta.type == "_assistant_reasoning_delta" then "reasoning" else "text" end) as $kind |
    if .[-1].type? == $kind then .[-1].text += $delta.text
    else . + [{type:$kind, text:$delta.text}] end) |
  select(any(.[]; .text != "")) |
  {type:"assistant", stop:"cancelled", content:.};
