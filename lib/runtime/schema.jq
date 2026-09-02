def profile_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$");

def theme_palette:
  type == "object" and
  (["muted", "divider", "footer", "prompt", "system_heading", "context",
    "user_heading", "agent_heading", "tool", "reasoning", "error", "syntax_comment",
    "syntax_keyword", "syntax_string", "syntax_number", "syntax_tag", "diff_added",
    "diff_added_background", "diff_removed", "diff_removed_background", "permission"] as $colors |
  ($colors - keys | length == 0) and
  ([$colors[] as $color | .[$color]] |
    all(.[]; type == "string" and test("^#[0-9A-Fa-f]{6}$"))));

def tool_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");

def nul_free_string:
  type == "string" and (index("\u0000") | not);

def tool_manifest:
  . as $manifest |
  def input_display($properties):
    type == "array" and all(.[]; nul_free_string) and
    all(.[] | select(startswith("$"));
      .[1:] as $field |
      $field == "input_json" or ($field != "" and ($properties | has($field))));
  def display_format:
    type == "string" and test("^[A-Za-z][A-Za-z0-9_+-]*$");
  def input_preview($properties):
    type == "object" and keys == ["content", "format"] and
    (.content | input_display($properties)) and (.format | display_format);
  def result_display:
    type == "array" and
    all(.[]; IN("$result_preview", "$result_full", "$exit_code")) and
    length == (unique | length) and
    ([.[] | select(. == "$result_preview" or . == "$result_full")] | length) <= 1;
  def result_preview:
    type == "object" and keys == ["content", "format"] and
    (.content | result_display) and (.format | display_format);
  type == "object" and
  ((keys - ["allow_sandbox_bypass", "description", "display", "input_schema",
    "sandbox"]) | length == 0) and
  (.description | nul_free_string and length > 0) and
  (.input_schema | type == "object" and .type == "object" and
    ((.properties // {}) | type == "object") and
    ((.required // []) | type == "array" and all(.[]; type == "string") and
      length == (unique | length)) and
    ((.properties // {}) |
      has("request_sandbox_bypass") or has("sandbox_bypass_reason") | not) and
    ((.required // []) |
      index("request_sandbox_bypass") == null and index("sandbox_bypass_reason") == null)) and
  ((if has("display") then .display else {} end) as $display |
    (.input_schema.properties // {}) as $properties |
    ($display | type == "object" and
      (keys - ["summary", "call", "permission_preview", "result"] | length) == 0 and
      ((if $display | has("summary") then $display.summary else [] end) |
        input_display($properties)) and
      ((if $display | has("call") then $display.call
        else {content:["$input_json"],format:"json"} end) |
        input_preview($properties)) and
      ((if $display | has("permission_preview") then $display.permission_preview
        else {content:["$input_json"],format:"json"} end) |
        input_preview($properties)) and
      ((if $display | has("result") then $display.result
        else {content:["$result_preview"],format:"plain"} end) |
        result_preview))) and
  (.sandbox | type == "boolean") and
  ((.allow_sandbox_bypass // false) | type == "boolean") and
  (if (.allow_sandbox_bypass // false) then .sandbox else true end);

def identifier:
  type == "string" and test("^[A-Za-z0-9_-]+$");

def element_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_.-]*$");

def nonempty_control_free_string:
  type == "string" and length > 0 and (test("[[:cntrl:]]") | not);

def model_name: nonempty_control_free_string;
def absolute_path: type == "string" and startswith("/") and (test("[[:cntrl:]]") | not);
def absolute_nul_free_path: nul_free_string and startswith("/");
def endpoint: type == "string" and test("^https?://[^[:space:][:cntrl:]]+$");
def positive_integer:
  type == "number" and floor == . and . >= 1 and . <= 2147483647;
def capture_bytes: positive_integer and . >= 64;
def preview_lines:
  . == "full" or (type == "number" and floor == . and . >= 0 and . <= 2147483647);
def token_count:
  type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
def api_key_env:
  type == "string" and test("^$|^[A-Za-z_][A-Za-z0-9_]*$") and
  (startswith("_SHELLFISH_") | not);

def backend_manifest:
  type == "object" and keys == ["api_key_env", "endpoint"] and
  (.endpoint | endpoint) and (.api_key_env | api_key_env);

def profile_fields:
  ["backend", "harness", "request"];
def harness_fields:
  ["tools", "sandbox", "sandbox_read_paths", "sandbox_write_paths",
   "max_requests_per_turn",
   "max_tool_calls_per_request", "max_capture_bytes"];
def hook_names:
  ["system", "session_start", "user_prompt_submit", "permission_request", "pre_tool_use",
   "post_tool_use", "stop"];

def harness_hooks:
  . as $harness |
  all(hook_names[]; . as $hook |
    ($harness | has($hook) | not) or
    ($harness[$hook] | type == "array" and all(.[]; absolute_path)));

def token_usage:
  type == "object" and
  ((keys - ["input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens"]) | length == 0) and
  (.input_tokens | token_count) and (.output_tokens | token_count) and
  (if has("cached_tokens") then
     (.cached_tokens | token_count) and .cached_tokens <= .input_tokens
   else true end) and
  (if has("reasoning_tokens") then .reasoning_tokens | token_count else true end);

def content_index:
  type == "number" and floor == . and . >= 0 and . <= 2147483647;

def canonical_backend_event:
  type == "object" and
  if .type == "_assistant_delta" or .type == "_assistant_reasoning_delta" then
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
  elif .type == "_assistant_response_end" then
    keys == ["stop", "type"] and (.stop | IN("end", "tool_calls", "length"))
  else false end;

def canonical_backend_response_events:
  type == "array" and length > 0 and all(.[]; canonical_backend_event) and
  .[-1].type == "_assistant_response_end" and
  ([.[] | select(.type == "_assistant_response_end")] | length) == 1;

def canonical_text:
  type == "object" and keys == ["text", "type"] and
  .type == "text" and (.text | type == "string");

def canonical_reasoning:
  type == "object" and .type == "reasoning" and (.text | type == "string") and
  ((has("opaque") | not) or (.opaque | type == "object"));

def canonical_tool_call:
  type == "object" and keys == ["id", "input", "name", "type"] and
  .type == "tool_call" and (.id | identifier) and (.name | tool_name) and
  (.input | type == "object");

def canonical_tool_result:
  type == "object" and
  ((keys - ["call_id", "content", "exit_code", "name", "role",
    "sandbox_denial_detected", "sandboxed", "type"]) | length == 0) and
  (["call_id", "content", "exit_code", "name", "role", "type"] - keys |
    length == 0) and
  .type == "message" and .role == "tool_result" and
  (.call_id | identifier) and (.name | tool_name) and (.content | type == "string") and
  (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255) and
  ((has("sandbox_denial_detected") | not) or .sandbox_denial_detected == true) and
  ((has("sandboxed") | not) or
    (.name == "shell" and (.sandboxed | type == "boolean")));

def canonical_user_message:
  type == "object" and keys == ["content", "role", "type"] and
  .type == "message" and .role == "user" and
  (.content | type == "array" and length == 1 and (.[0] | canonical_text)) and
  (.content[0].text | nul_free_string);

def canonical_assistant_message:
  type == "object" and .type == "message" and .role == "assistant" and
  (.stop | IN("end", "tool_calls", "length")) and
  ((has("usage") | not) or (.usage | token_usage)) and
  (.content | type == "array" and
    all(.[]; canonical_text or canonical_reasoning or canonical_tool_call)) and
  (([.content[] | select(.type == "tool_call")] | length) as $calls |
    if .stop == "tool_calls" then $calls > 0
    else $calls == 0 end) and
  ([.content[] | select(.type == "tool_call") | .id] | length) ==
  ([.content[] | select(.type == "tool_call") | .id] | unique | length);

def canonical_context:
  type == "object" and
  (keys - ["content", "hook", "prompt", "script", "status", "type"] | length) == 0 and
  .type == "context" and (.hook | element_name) and
  (.content | type == "string") and
  (.script | nonempty_control_free_string) and
  ((has("prompt") | not) or ((.prompt | nul_free_string and length > 0) and has("status"))) and
  ((has("status") | not) or
    (.status | type == "number" and floor == . and . >= 0 and . <= 255));

def canonical_request:
  type == "object" and .format_version == 1 and (.system | type == "string") and
  (.messages | type == "array" and all(.[];
    (.role == "user" and (.content | type == "array")) or
    (.role == "assistant" and (.content | type == "array")) or
    (.role == "tool_result" and (.content | type == "string")))) and
  (.tools | type == "array") and
  (.options.request | type == "object" and (.model | model_name)) and
  (.transport.endpoint | endpoint) and (.transport.insecure_tls | type == "boolean") and
  (.transport.http_timeout | positive_integer) and (.transport.http_stall | positive_integer);

def canonical_session_header($format_version):
  type == "object" and .type == "session" and .format_version == $format_version and
  (.cwd | absolute_nul_free_path) and (.created | type == "string") and
  (.profile | type == "object" and keys == ["request"] and
    (.request | type == "object" and (.model | model_name))) and
  (.backend | type == "object" and keys ==
    ["api_key_env", "command", "endpoint", "env_file", "http_stall", "http_timeout", "insecure_tls", "name"] and
    (.name | profile_name) and (.command | absolute_path) and (.endpoint | endpoint) and
    (.api_key_env | api_key_env) and (.insecure_tls | type == "boolean") and
    (.env_file == "" or (.env_file | absolute_nul_free_path)) and
    (.http_timeout | positive_integer) and (.http_stall | positive_integer)) and
  (.harness | type == "object" and
    (["sandbox_read_paths", "sandbox_write_paths", "fence",
      "max_capture_bytes", "max_requests_per_turn",
      "max_tool_calls_per_request", "sandbox", "system", "tools"] as $required |
      ((keys - ($required + hook_names)) | length == 0) and
      (($required - keys) | length == 0)) and
    harness_hooks and
    (.sandbox_read_paths | type == "array" and all(.[]; absolute_nul_free_path)) and
    (.sandbox_write_paths | type == "array" and all(.[]; absolute_nul_free_path)) and
    (.fence == "" or (.fence | absolute_path)) and
    (.tools | type == "array" and all(.[];
      type == "object" and keys == ["command", "manifest", "name", "settings"] and
      (.name | tool_name) and (.command | absolute_path) and
      (.settings == null or (.settings | type == "object")) and
      (.manifest | tool_manifest) and
      (if .manifest.sandbox then .settings != null else .settings == null end))) and
    (([.tools[].name] | unique | length) == (.tools | length)) and
    (.sandbox | type == "boolean") and
    (.max_requests_per_turn | positive_integer) and
    (.max_tool_calls_per_request | positive_integer) and
    (.max_capture_bytes | capture_bytes));

def canonical_session_record:
  canonical_user_message or canonical_assistant_message or canonical_tool_result or
  canonical_context or
  (type == "object" and keys == ["content", "type"] and .type == "system" and
    (.content | nul_free_string));

def canonical_session_records:
  reduce .[] as $record
    ({valid:true, next:"user", pending:[]};
      if (.valid | not) or ($record | canonical_session_record | not) then
        .valid = false
      elif $record.type == "system" then
        if .next == "user" then . else .valid = false end
      elif $record.type == "context" then
        if $record.hook == "stop" and .next == "user" then .next = "assistant"
        elif $record.hook != "stop" and .next == "user" then .
        else .valid = false end
      elif $record.role == "user" then
        if .next == "user" then .next = "assistant" else .valid = false end
      elif $record.role == "assistant" then
        if .next != "assistant" then .valid = false
        elif $record.stop == "tool_calls" then
          .next = "tool" |
          .pending = [$record.content[] | select(.type == "tool_call") | {id,name}]
        else .next = "user" end
      elif $record.role == "tool_result" then
        if .next != "tool" or (.pending | length) == 0 or
            $record.call_id != .pending[0].id or $record.name != .pending[0].name then
          .valid = false
        else
          .pending = .pending[1:] |
          if (.pending | length) == 0 then .next = "assistant" else . end
        end
      else .valid = false end) |
  .valid;
