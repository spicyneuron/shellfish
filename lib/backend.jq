# Adapter request and response protocol.

def backend_adapter_request($model; $system; $messages; $tools):
  {
    format_version:1,
    system:$system,
    messages:$messages,
    tools:$tools,
    request:$model.request,
    endpoint:$model.endpoint
  } | select(all(.messages[] | select(.type == "user");
    .content[0].text | index("\u0000") | not));

# Display-only text an adapter streams before its response.
def backend_preview:
  type == "object" and keys == ["text", "type"] and
  (.type == "_assistant_message_delta" or .type == "_assistant_reasoning_delta") and
  (.text | type == "string");

# Previews pass through until one complete response ends the stream. Anything
# else, including a line after the response, is invalid. A response nothing
# previewed previews its own text first, so clients always see it arrive.
def decode_backend_response(valid_response):
  def event: ["event", "\u0000", tojson, "\u0000"];
  foreach inputs as $line ({ended:false, previewed:false, out:[]};
    if .ended then halt_error(1)
    elif $line | backend_preview then
      .previewed = true | .out = ($line | event)
    elif $line | type == "object" and .stop != "cancelled" and valid_response then
      .ended = true |
      .out = (if .previewed then []
        else [$line.content[] | select((.type == "text" or .type == "reasoning") and .text != "") |
          {type:(if .type == "text" then "_assistant_message_delta"
                 else "_assistant_reasoning_delta" end), text} | event[]] end) +
        ["end", "\u0000", ($line | tojson), "\u0000"]
    else halt_error(1) end;
    .out[]);

# Previews joined into the response they were showing, for a cancelled request.
def backend_preview_response:
  reduce .[] as $preview ([];
    (if $preview.type == "_assistant_reasoning_delta" then "reasoning" else "text" end) as $kind |
    if .[-1].type? == $kind then .[-1].text += $preview.text
    else . + [{type:$kind, text:$preview.text}] end) |
  select(any(.[]; .text != "")) |
  {type:"assistant", stop:"cancelled", content:.};
