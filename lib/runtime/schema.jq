def profile_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$");

def tool_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");

def component_environment:
  type == "array" and
  all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")) and
  length == (unique | length);

def nul_free_string:
  type == "string" and (index("\u0000") | not);

def script_template($input_variables; $output):
  type == "string" and (index("\u0000") | not) and
  (gsub("\\$\\{[^{}]+\\}"; "") | index("${") | not) and
  ([scan("\\$\\{([^{}]+)\\}")[0]] | all(.[];
    . == "name" or . == "input" or
    (if $input_variables == null then test("^input\\.[A-Za-z_][A-Za-z0-9_]*$")
     else . as $name | $input_variables | index($name) != null end) or
    ($output and IN("output.stdout", "output.stderr", "output.exit_code"))));

def tool_render($input_variables):
  type == "object" and keys == ["model", "permission", "running", "user"] and
  (.running | script_template($input_variables; false)) and
  (.permission | script_template($input_variables; false)) and
  (.user | script_template($input_variables; true)) and
  (.model | script_template($input_variables; true));

def tool_manifest:
  (.input_schema.properties // {} | keys | map("input." + .)) as $input_variables |
  type == "object" and
  ((keys - ["allow_sandbox_bypass", "description", "environment",
    "input_schema", "render", "sandbox"]) | length == 0) and
  (.description | nul_free_string and length > 0) and
  (.input_schema | type == "object" and .type == "object" and
    ((.properties // {}) | type == "object") and
    ((.required // []) | type == "array" and all(.[]; type == "string") and
      length == (unique | length)) and
    ((.properties // {}) |
      has("request_sandbox_bypass") or has("sandbox_bypass_reason") | not) and
    ((.required // []) |
      index("request_sandbox_bypass") == null and index("sandbox_bypass_reason") == null)) and
  (.render | tool_render($input_variables)) and
  ((.environment // []) | component_environment) and
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
def token_count:
  type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
def hook_names:
  ["session_start", "user_prompt_submit", "permission_request", "pre_tool_use",
   "post_tool_use", "stop"];

def hook_match:
  type == "object" and
  if keys == ["pattern"] then
    .pattern as $pattern |
    ($pattern | type == "string" and length > 0 and
      (test("[[:cntrl:]]") | not)) and
    (try ("" | test($pattern) | type == "boolean") catch false)
  elif keys == ["command"] then .command | absolute_path
  else false end;

def hook_text:
  type == "string" and (test("[[:cntrl:]]") | not);

def hook_help:
  type == "object" and keys == ["description", "usage"] and
  (.usage | hook_text and length > 0) and
  (.description | hook_text and length > 0);

def hook_component:
  type == "object" and
  (keys - ["command", "environment", "help", "match", "running"] | length) == 0 and
  has("command") and has("environment") and has("running") and
  (.command | absolute_path) and
  (.running | script_template(null; false)) and
  (.environment | component_environment) and
  (if has("match") then .match | hook_match else true end) and
  (if has("help") then .help | hook_help else true end);

def harness_hooks:
  . as $harness |
  all(hook_names[]; . as $hook |
    ($harness | has($hook) | not) or
    ($harness[$hook] | type == "array" and all(.[];
      hook_component and
      (if $hook == "user_prompt_submit" then
         (has("help") | not) or has("match")
       else ((has("match") or has("help")) | not) end))));

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

def request_text:
  type == "object" and keys == ["text", "type"] and
  .type == "text" and (.text | type == "string");

def request_reasoning:
  type == "object" and .type == "reasoning" and (.text | type == "string") and
  ((has("opaque") | not) or (.opaque | type == "object"));

def request_tool_call:
  type == "object" and keys == ["id", "input", "name", "type"] and
  .type == "tool_call" and (.id | identifier) and (.name | tool_name) and
  (.input | type == "object");

def canonical_tool_activity:
  type == "object" and
  ((keys - ["id", "input", "name", "type", "user_text"]) | length == 0) and
  ((["id", "input", "name", "type"] - keys) | length == 0) and
  .type == "_tool_activity" and (.id | identifier) and
  (.name | tool_name) and (.input | type == "object") and
  (if has("user_text") then .user_text | type == "string" and length > 0 else true end);

def request_user_message:
  type == "object" and keys == ["content", "type"] and .type == "user" and
  (.content | type == "array" and length == 1 and (.[0] | request_text)) and
  (.content[0].text | nul_free_string);

def request_assistant_message:
  type == "object" and .type == "assistant" and
  ((keys - ["content", "stop", "type", "usage"]) | length == 0) and
  (["content", "stop", "type"] - keys | length == 0) and
  (.stop | IN("end", "tool_calls", "length", "cancelled")) and
  ((has("usage") | not) or (.usage | token_usage)) and
  (.content | type == "array" and
    all(.[]; request_text or request_reasoning));

def canonical_request:
  type == "object" and
  keys == ["format_version", "messages", "options", "system", "tools", "transport"] and
  .format_version == 1 and (.system | type == "string") and
  (.messages | type == "array" and all(.[];
    type == "object" and
    if .type == "user" then request_user_message
    elif .type == "assistant" then
      keys == ["content", "stop", "type"] and
      (.content | type == "array" and all(.[];
        if type == "object" and .type == "reasoning" then
          keys == ["text", "type"] or keys == ["opaque", "text", "type"]
        else true end)) and
      request_assistant_message
    elif .type == "tool_call" then request_tool_call
    elif .type == "tool_result" then
      keys == ["call_id", "content", "exit_code", "name", "type"] and
      (.call_id | identifier) and (.name | tool_name) and
      (.content | type == "string") and
      (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255)
    else false end)) and
  (.tools | type == "array" and all(.[];
    type == "object" and keys == ["description", "input_schema", "name"] and
    (.name | tool_name) and (.description | nul_free_string and length > 0) and
    (.input_schema | type == "object" and .type == "object" and
      ((.properties // {}) | type == "object") and
      ((.required // []) | type == "array" and all(.[]; type == "string") and
        length == (unique | length)))) and
    ([.[].name] | length) == ([.[].name] | unique | length)) and
  (.options | type == "object" and keys == ["request"] and
    (.request | type == "object" and (.model | model_name))) and
  (.transport | type == "object" and
    keys == ["endpoint", "http_stall", "http_timeout", "insecure_tls"] and
    (.endpoint | endpoint) and (.insecure_tls | type == "boolean") and
    (.http_timeout | positive_integer) and (.http_stall | positive_integer));

def canonical_session_header($format_version):
  type == "object" and .type == "session" and .format_version == $format_version and
  (.cwd | absolute_nul_free_path) and (.created | type == "string") and
  (.profile | type == "object" and
    ((keys - ["context_window", "request", "system"]) | length == 0) and
    (["request"] - keys | length == 0) and
    (.request | type == "object" and (.model | model_name)) and
    ((has("system") | not) or
      (.system | type == "array" and all(.[]; absolute_nul_free_path))) and
    (if has("context_window") then
      .context_window == null or (.context_window | positive_integer)
    else true end)) and
  (.backend | type == "object" and
    ((keys - ["command", "context_window_command", "endpoint", "env_file", "environment", "http_stall", "http_timeout", "insecure_tls", "name"]) | length == 0) and
    (["command", "endpoint", "env_file", "environment", "http_stall", "http_timeout", "insecure_tls", "name"] - keys | length == 0) and
    (.name | profile_name) and (.command | absolute_path) and (.endpoint | endpoint) and
    (.environment | component_environment) and (.insecure_tls | type == "boolean") and
    (.env_file == "" or (.env_file | absolute_nul_free_path)) and
    (.http_timeout | positive_integer) and (.http_stall | positive_integer) and
    (if has("context_window_command") then
      .context_window_command | absolute_path
    else true end)) and
  (.harness | type == "object" and
    (["sandbox_read_paths", "sandbox_write_paths", "fence",
      "max_capture_bytes", "max_requests_per_turn",
      "max_tool_calls_per_request", "sandbox", "tools"] as $required |
      ((keys - ($required + hook_names)) | length == 0) and
      (($required - keys) | length == 0)) and
    harness_hooks and
    (.sandbox_read_paths | type == "array" and all(.[]; absolute_nul_free_path)) and
    (.sandbox_write_paths | type == "array" and all(.[]; absolute_nul_free_path)) and
    (.fence == "" or (.fence | absolute_path)) and
    (.tools | type == "array" and all(.[];
      type == "object" and keys == ["command", "manifest", "name", "settings"] and
      (.name | tool_name) and (.command | absolute_path) and
      (.settings == null or (.settings | absolute_nul_free_path)) and
      (.manifest | tool_manifest) and
      (if .manifest.sandbox then .settings != null else .settings == null end))) and
    (([.tools[].name] | unique | length) == (.tools | length)) and
    (.sandbox | type == "boolean") and
    (.max_requests_per_turn | positive_integer) and
    (.max_tool_calls_per_request | positive_integer) and
    (.max_capture_bytes | capture_bytes));
