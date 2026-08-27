def profile_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$");

def theme_palette:
  type == "object" and
  (["muted_color", "divider_color", "footer_color", "prompt_color",
    "system_heading_color",
    "context_color", "user_heading_color", "agent_heading_color", "tool_color",
    "reasoning_color",
    "error_color", "added_color", "added_background_color", "removed_color",
    "removed_background_color", "permission_color"] as $colors |
  ($colors - keys | length == 0) and
  ([$colors[] as $color | .[$color]] |
    all(.[]; type == "string" and test("^#[0-9A-Fa-f]{6}$"))));

def tool_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");

def nul_free_string:
  type == "string" and (index("\u0000") | not);

def tool_manifest:
  . as $manifest |
  def display_phase($fields):
    type == "object" and ((keys - $fields) | length) == 0 and
    ((.always_full // false) | type == "boolean");
  def valid_result:
    .result as $result |
    ($result | type == "object" and keys == ["path_field", "type"]) and
    $result.type == "file_diff" and
    ($result.path_field | type == "string" and
      test("^[A-Za-z_][A-Za-z0-9_-]*$")) and
    (.input_schema.properties[$result.path_field] as $path |
      $path.type? == "string" and ($path.minLength? // 0) >= 1) and
    ([.input_schema.required[]?] | index($result.path_field) != null);
  type == "object" and
  ((keys - ["allow_sandbox_bypass", "description", "display", "input_schema",
    "result", "sandbox"]) | length == 0) and
  (.description | nul_free_string and length > 0) and
  (.input_schema | type == "object" and .type == "object" and
    ((.properties // {}) | type == "object") and
    ((.required // []) | type == "array" and all(.[]; type == "string") and
      length == (unique | length)) and
    ((.properties // {}) |
      has("request_sandbox_bypass") or has("sandbox_bypass_reason") | not) and
    ((.required // []) |
      index("request_sandbox_bypass") == null and index("sandbox_bypass_reason") == null)) and
  ((.display // {}) as $display | (.input_schema.properties // {}) as $properties |
    ($display | type == "object" and
      (keys - ["call", "result"] | length) == 0 and
      ((.call // {}) | display_phase(["always_full", "content"]) and
        ((.content // []) | type == "array" and all(.[]; nul_free_string))) and
      ((.result // {}) | display_phase(["always_full", "exit_code"]) and
        ((.exit_code // false) | type == "boolean"))) and
    all(($display.call.content // [])[] | select(startswith("$"));
      .[1:] as $field | $field != "" and ($properties | has($field)))) and
  (.sandbox | type == "boolean") and
  ((.allow_sandbox_bypass // false) | type == "boolean") and
  (if (.allow_sandbox_bypass // false) then .sandbox else true end) and
  ((has("result") | not) or valid_result);

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
  ["system", "tools", "sandbox", "sandbox_read_paths", "sandbox_write_paths",
   "max_requests_per_turn",
   "max_tool_calls_per_request", "max_capture_bytes"];
def hook_event_names:
  ["session_start", "user_prompt_submit", "permission_request", "pre_tool_use",
   "post_tool_use", "stop"];

def harness_hooks:
  . as $harness |
  all(hook_event_names[]; . as $event |
    ($harness | has($event) | not) or
    ($harness[$event] | type == "array" and all(.[]; absolute_path)));

def token_usage:
  type == "object" and
  ((keys - ["input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens"]) | length == 0) and
  (.input_tokens | token_count) and (.output_tokens | token_count) and
  (if has("cached_tokens") then
     (.cached_tokens | token_count) and .cached_tokens <= .input_tokens
   else true end) and
  (if has("reasoning_tokens") then .reasoning_tokens | token_count else true end);

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
    "result_type", "sandboxed", "type"]) | length == 0) and
  (["call_id", "content", "exit_code", "name", "role", "type"] - keys |
    length == 0) and
  .type == "message" and .role == "tool_result" and
  (.call_id | identifier) and (.name | tool_name) and (.content | type == "string") and
  (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255) and
  ((has("result_type") | not) or .result_type == "file_diff") and
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
  (keys - ["content", "hook", "prompt", "status", "tag", "type"] | length) == 0 and
  .type == "context" and (.tag | element_name) and
  (.content | type == "string") and
  (.hook | nonempty_control_free_string) and
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
      "max_tool_calls_per_request", "sandbox", "tools"] as $required |
      ((keys - ($required + hook_event_names)) | length == 0) and
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
        if $record.tag == "stop" and .next == "user" then .next = "assistant"
        elif $record.tag != "stop" and .next == "user" then .
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
