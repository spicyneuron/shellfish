# Durable record validity and transcript order. Records are read left to right;
# each view projects the state this reduction reaches. lib/profile.jq owns the
# header, which validates the profile nested inside it.
#
# Repeated primitives are deliberate; see AGENTS.md.

def nul_free_string: type == "string" and (index("\u0000") | not);
def identifier: type == "string" and test("^[A-Za-z0-9_-]+$");
def tool_name: type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");
def token_count:
  type == "number" and floor == . and . >= 0 and . <= 9007199254740991;

def section_id: type == "number" and floor == . and . > 0 and . <= 999999999;
def section_field: (has("section") | not) or (.section | section_id);

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

# Transcript images are inline data URIs, never references.
def canonical_image:
  type == "object" and keys == ["type", "url"] and .type == "image" and
  (.url | type == "string" and
    test("^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/]+={0,2}$"));

def canonical_content_part: canonical_text or canonical_image;

def canonical_reasoning:
  type == "object" and
  (keys == ["text", "type"] or keys == ["opaque", "text", "type"]) and
  .type == "reasoning" and (.text | type == "string") and
  ((has("opaque") | not) or (.opaque | type == "object"));

def canonical_tool_call:
  type == "object" and keys == ["id", "input", "name", "type"] and
  .type == "tool_call" and (.id | identifier) and (.name | tool_name) and
  (.input | type == "object");

# The prompt text leads, followed by any attached images.
def canonical_user_message:
  type == "object" and (del(.section) | keys == ["content", "type"]) and
  section_field and .type == "user" and
  (.content | type == "array" and (.[0] | canonical_text) and
    all(.[1:][]; canonical_image)) and
  (.content[0].text | nul_free_string);

def canonical_state_update:
  type == "object" and keys == ["name", "type", "value"] and .type == "state_update" and
  (.name | type == "string" and length <= 128 and
    test("^[A-Za-z0-9][A-Za-z0-9_.:/-]*\\z"));

def canonical_error:
  type == "object" and (del(.section) | keys == ["type", "user_text"]) and
  section_field and .type == "error" and
  (.user_text | nul_free_string) and .user_text != "";

def preview_hint:
  . == "full" or (type == "number" and floor == . and . >= 0 and . <= 2147483647);

# A settled result: its REQUIRED fields plus optional texts, nonempty when
# present, and a preview hint.
def result_fields($required):
  type == "object" and
  ((keys - ($required + ["model_text", "type", "user_preview_lines", "user_text"])) |
    length == 0) and
  (($required - keys) | length == 0) and
  (if has("user_text") then .user_text | type == "string" and length > 0 else true end) and
  (if has("model_text") then .model_text | type == "string" and length > 0 else true end) and
  ((has("user_preview_lines") | not) or (.user_preview_lines | preview_hint));

def model_content_fields:
  (has("model_content") | not) or ((has("model_text") | not) and
    (.model_content | type == "array" and length > 0 and
      all(.[]; canonical_content_part)));

# A settled sandbox access request records whether it was approved, and
# whether for the session. Model content replaces model text.
def canonical_tool_result:
  section_field and (del(.section, .sandbox_access, .model_content) |
    result_fields(["exit_code", "id", "input", "name"])) and
  ((has("sandbox_access") | not) or
    (.sandbox_access | IN("approved", "session", "denied", "cancelled"))) and
  model_content_fields and
  .type == "tool_result" and
  (.id | identifier) and (.name | tool_name) and (.input | type == "object") and
  (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255);

def canonical_hook_result:
  section_field and (del(.section, .action, .reason, .model_content) | result_fields(["id", "lifecycle"])) and
  model_content_fields and
  .type == "hook_result" and (.lifecycle | record_lifecycle) and
  (.id | test("^[1-9][0-9]*$")) and
  (if has("action") then .action == "deny" and
    (.lifecycle | IN("user_prompt_submit", "permission_request", "pre_tool_use", "stop")) and
    ((has("reason") | not) or (.reason | type == "string"))
   else has("reason") | not end);

def response_calls: [.content[] | select(.type == "tool_call")];

# One complete provider response. Only a tool-calling stop carries calls.
def canonical_response:
  type == "object" and .type == "assistant" and
  ((keys - ["content", "section", "stop", "type", "usage"]) | length == 0) and
  section_field and
  ((["content", "stop", "type"] - keys) | length == 0) and
  (.stop | IN("end", "tool_calls", "length", "cancelled")) and
  ((has("usage") | not) or (.usage | token_usage)) and
  (.content | type == "array" and
    all(.[]; canonical_text or canonical_reasoning or canonical_tool_call)) and
  (response_calls as $calls |
    if .stop == "tool_calls" then
      ($calls | length) > 0 and (([$calls[].id] | unique | length) == ($calls | length))
    else ($calls | length) == 0 end);

# Attachments turn text-only context into content parts.
def join_content:
  if any(.[]; type == "array") then
    [to_entries[] | (if .key > 0 then {type:"text",text:"\n\n"} else empty end),
      (.value | if type == "array" then .[] else {type:"text",text:.} end)]
  else join("\n\n") end;

# Hook results from one lifecycle share a group.
def render_context:
  if type == "string" or type == "array" then .
  elif any(.texts[]; type == "array") then
    [{type:"text",text:("<hook name=\"" + (.lifecycle | @html) + "\">\n")}] +
      (.texts | join_content) + [{type:"text",text:"\n</hook>"}]
  else
    "<hook name=\"" + (.lifecycle | @html) + "\">\n" +
    ([.texts[] | if endswith("\n") then . else . + "\n" end] | add) + "</hook>"
  end;

def add_hook_context($record):
  ($record.model_content // $record.model_text) as $content |
  ([to_entries[] | select(.value.lifecycle? == $record.lifecycle) | .key] | first) as $index |
  if $index == null then . + [{lifecycle:$record.lifecycle,texts:[$content]}]
  else .[$index].texts += [$content] end;

def join_context($parts):
  [$parts[] | select(. != "") | render_context] | join_content;

def context_message($context; $request):
  {type:"user", content:(join_context([$context[], $request]) |
    if type == "array" then . else [{type:"text",text:.}] end)};

def claim_section($record):
  if $record.section == null then .
  elif ($record.type | IN("tool_result", "hook_result")) then
    if $record.section == .agent_section then . else error("wrong agent section") end
  elif ($record.type | IN("assistant", "error")) and .agent_section != null then
    if $record.section == .agent_section then . else error("wrong assistant section") end
  elif (.sections | index($record.section)) != null then error("repeated section")
  else .sections += [$record.section] |
    if ($record.type | IN("assistant", "error")) then .agent_section = $record.section else . end
  end;

def session_state:
  reduce .[] as $record
    ({next:"user", calls:[], context:[], hooks:[], messages:[], response:null,
      requests:0, call_total:0, sections:[], agent_section:null};
      if ($record | canonical_state_update) then .
      elif ($record | canonical_hook_result) then
        claim_section($record) |
        if (.hooks | index($record.id)) != null then
          error("repeated hook id: " + $record.id)
        else
          .hooks += [$record.id] |
          (if $record.lifecycle == "stop" and $record.action? == "deny" then
             .next = "assistant"
           else . end) |
          if ($record.model_content // $record.model_text // "") == "" then .
          # Post-tool context annotates the result it follows.
          elif $record.lifecycle == "post_tool_use" and (.context | length) == 0 and
              .messages[-1].type? == "tool_result" then
            .messages[-1].parts |= add_hook_context($record)
          else .context |= add_hook_context($record) end
        end
      elif ($record | canonical_error) then
        claim_section($record) |
        .next = "user" | .calls = [] | .response = null
      elif ($record | canonical_user_message) then
        if .next != "user" then error("user request inside a turn") else . end |
        .agent_section = null | claim_section($record) |
        .messages += [context_message(.context; $record.content[0].text) |
          .content += $record.content[1:]] |
        .context = [] | .next = "assistant" | .requests = 0
      elif ($record | canonical_response) then
        if .next == "assistant" then .
        else error("response outside a turn") end |
        claim_section($record) |
        (if (.context | length) == 0 then .
         else .messages += [context_message(.context; "")] | .context = [] end) |
        ($record | response_calls) as $calls |
        .requests += 1 | .call_total = ($calls | length) |
        if ($calls | length) == 0 then
          .messages += [$record | del(.section, .usage)] | .next = "user"
        else .calls = $calls | .response = $record | .next = "tool_result" end
      elif ($record | canonical_tool_result) then
        claim_section($record) |
        (if (.calls | length) == 0 then error("tool result without a call")
         else .calls[0] end) as $call |
        if $call.id != $record.id or $call.name != $record.name or
            $call.input != $record.input then
          error("tool result does not settle its call: " + $record.id)
        else . end |
        (if .response == null then .
         else
           .messages += [.response | del(.section, .usage) |
             .content = [.content[] | select(.type != "tool_call")]] |
           .response = null
         end) |
        .messages += [{type:"tool_call", id:$call.id, name:$call.name, input:$call.input},
          {type:"tool_result", call_id:$call.id, name:$call.name,
           exit_code:$record.exit_code, parts:.context,
           result:($record.model_content // $record.model_text // "")}] |
        .context = [] |
        .calls = .calls[1:] |
        .next = (if (.calls | length) == 0 then "assistant" else "tool_result" end)
      else error("unrecognized session record") end);

# A response awaiting results reaches no request, and trailing context waits
# here for the request that carries it. A result with model content is a part
# array, led by any context.
def state_messages:
  [.messages[] |
    if .type == "tool_result" then
      .content = (if (.result | type == "array") or any(.parts[].texts[]?; type == "array") then
          (join_context(.parts) | if type == "array" then .
            else [select(. != "") | {type:"text",text:.}] end) +
          (.result | if type == "array" then .
            else [select(. != "") | {type:"text",text:.}] end)
        else join_context([.parts[], .result]) end) |
      del(.parts, .result)
    else . end] +
  if (.context | length) == 0 then [] else [context_message(.context; "")] end;

def session_messages: session_state | state_messages;
