# Adapter request and response protocol.

def adapter_envelope($model):
  {format_version:1, request:$model.request, endpoint:$model.endpoint} +
  (if $model | has("config") then {config:$model.config} else {} end);

def backend_adapter_request($model; $system; $messages; $tools):
  adapter_envelope($model) + {system:$system, messages:$messages, tools:$tools} |
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

# A decision asks typed questions about one input and receives one answer each.

def decision_url: type == "string" and test("^(data:|https?://)\\S+$");

def decision_block:
  type == "object" and
  if .type == "text" then keys == ["text", "type"] and (.text | type == "string")
  elif .type == "json" then keys == ["data", "type"]
  elif .type == "image" or .type == "video" then keys == ["type", "url"] and (.url | decision_url)
  else false end;

def decision_question:
  type == "object" and (.instructions | type == "string") and
  if .type == "predicate" then
    (keys - ["criteria"]) == ["instructions", "type"] and
    ((has("criteria") | not) or (.criteria | type == "object" and
      (keys - ["false", "true"]) == [] and all(.[]; type == "string")))
  elif .type == "choice" then
    keys == ["choices", "instructions", "type"] and
    (.choices | type == "object" and length >= 2 and length <= 255 and
      all(keys[]; length > 0) and all(.[]; . == null or type == "string"))
  elif .type == "score" then
    keys == ["instructions", "levels", "type"] and
    (.levels | type == "array" and length >= 2 and length <= 10 and all(.[]; type == "string"))
  else false end;

def decision_request:
  def check(valid; $message): if valid then . else error($message) end;
  check(type == "object" and (keys - ["input", "questions", "system"]) == [] and
    has("input") and has("questions"); "expected input, questions, and optional system") |
  check((has("system") | not) or (.system | type == "string"); "system must be a string") |
  check(.input | type == "array" and length > 0; "input must be a nonempty array") |
  check(all(.input[]; decision_block); "input blocks must be text, json, image, or video") |
  check(.questions | type == "object" and length > 0; "questions must be a nonempty object") |
  reduce (.questions | to_entries[]) as $entry (.;
    check($entry.key | test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$");
      "invalid question name: \($entry.key)") |
    check($entry.value | decision_question; "invalid question: \($entry.key)"));

def decision_adapter_request($model; $decision):
  adapter_envelope($model) + {system:($decision.system // ""), input:$decision.input,
    questions:$decision.questions};

def decision_unit: type == "number" and . >= 0 and . <= 1;

def decision_answer($question):
  type == "object" and
  if .type == "refusal" then keys == ["type"]
  elif .type != $question.type then false
  elif .type == "predicate" then keys == ["probability", "type"] and (.probability | decision_unit)
  elif .type == "choice" then
    keys == ["choice", "confidence", "probabilities", "type"] and (.confidence | decision_unit) and
    (.choice as $choice | $choice | type == "string" and ($question.choices | has($choice))) and
    (.probabilities | type == "object" and keys == ($question.choices | keys) and
      all(.[]; decision_unit))
  elif .type == "score" then
    ($question.levels | length) as $levels |
    keys == ["confidence", "probabilities", "score", "type"] and (.confidence | decision_unit) and
    (.score | type == "number" and . >= 0 and . <= $levels - 1) and
    (.probabilities | type == "array" and length == $levels and all(.[]; decision_unit))
  else false end;

# The caller checks usage, whose shape the session module owns.
def decision_result($questions):
  type == "object" and (keys - ["usage"]) == ["answers", "model"] and
  (.model | type == "string" and length > 0) and
  (.answers | type == "object" and keys == ($questions | keys) and
    all(to_entries[]; . as $entry | $entry.value | decision_answer($questions[$entry.key])));
