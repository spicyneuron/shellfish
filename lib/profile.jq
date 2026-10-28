# Profiles and model files, the session header that freezes their resolution,
# and component manifests and their templates. The header lives here rather
# than in lib/session.jq because it validates the profile nested inside it.
#
# Repeated primitives are deliberate; see AGENTS.md.

def tool_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");

def nul_free_string:
  type == "string" and (index("\u0000") | not);

def nonempty_control_free_string:
  type == "string" and length > 0 and (test("[[:cntrl:]]") | not);

def model_name: nonempty_control_free_string;
# A path: absolute, under HOME as "~/", or under the bundled root as "@".
def stored_reference:
  nonempty_control_free_string and
  (startswith("/") or startswith("~/") or startswith("@"));
def stored_cwd:
  nonempty_control_free_string and (startswith("/") or startswith("~/"));
def endpoint: type == "string" and test("^https?://[^[:space:][:cntrl:]]+$");

def positive_integer:
  type == "number" and floor == . and . >= 1 and . <= 2147483647;
def capture_bytes: positive_integer and . >= 64;
def component_preview_hint:
  . == "full" or (type == "number" and floor == . and . >= 0 and . <= 2147483647);

def hook_names:
  ["session_start", "user_prompt_submit", "permission_request", "pre_tool_use",
   "post_tool_use", "stop"];

# A template may name component values and declared input properties.
def component_template($fields):
  type == "string" and (index("\u0000") | not) and
  (gsub("\\$\\{[^{}]+\\}"; "") | index("${") | not) and
  ([scan("\\$\\{([^{}]+)\\}")[0]] |
    all(.[]; IN("name", "input", "output.stdout", "output.stderr", "output.exit_code") or
      test("^data\\.[A-Za-z_][A-Za-z0-9_]*$") or
      (. as $field | $fields | index($field) != null)));

# Component input is text or an object; strings substitute as-is, null as
# nothing, and other values as JSON. An absent template renders empty.
def render_template($template; $name; $input; $output; $data):
  def text: if type == "string" then . elif . == null then "" else tojson end;
  ({name:$name, input:($input | text)} +
    ($input | if type == "object" then
      with_entries(.key = "input." + .key | .value |= text)
    else {} end) +
    ($output | with_entries(.key = "output." + .key | .value |= text)) +
    ($data | with_entries(.key = "data." + .key | .value |= text))) as $variables |
  $template // "" | gsub("\\$\\{(?<name>[^{}]+)\\}"; $variables[.name] // "");

def component_templates: ["user_text", "user_text_done", "user_text_skipped", "model_text"];
def tool_inputs: .input_schema.properties // {} | keys | map("input." + .);

# Shared presentation with caller-supplied keys and template fields.
def component_manifest($attrs; $fields):
  type == "object" and
  ((keys - component_templates - ["user_preview_lines", "max_capture_bytes"] - $attrs) | length == 0) and
  all(.[component_templates[]]; . == null or component_template($fields)) and
  ((has("user_preview_lines") | not) or (.user_preview_lines | component_preview_hint)) and
  ((has("max_capture_bytes") | not) or (.max_capture_bytes | capture_bytes));

# "on" names the lifecycle a profile binds the hook to.
def hook_manifest:
  component_manifest(["match", "on"]; []) and
  ((has("on") | not) or (.on | IN(hook_names[]))) and
  ((has("match") | not) or
    (.match | type == "object" and keys == ["pattern"] and
      (.pattern as $pattern | $pattern | type == "string" and
        (try ("" | test($pattern) | type == "boolean") catch false))));

def tool_manifest:
  tool_inputs as $inputs |
  component_manifest(["allow_sandbox_bypass", "description", "environment",
    "input_schema", "sandbox", "user_permission", "user_text_unsandboxed",
    "user_text_done_unsandboxed"]; $inputs) and
  all([.user_text_unsandboxed, .user_text_done_unsandboxed][];
    . == null or component_template($inputs)) and
  (.description | nul_free_string and length > 0) and
  (.input_schema | type == "object" and .type == "object" and
    ((.properties // {}) | type == "object") and
    ((.required // []) | type == "array" and all(.[]; type == "string") and
      length == (unique | length)) and
    ((.properties // {}) |
      has("request_sandbox_bypass") or has("sandbox_bypass_reason") | not) and
    ((.required // []) |
      index("request_sandbox_bypass") == null and index("sandbox_bypass_reason") == null)) and
  (.user_permission == null or (.user_permission | component_template($inputs))) and
  ((.environment // []) | type == "array" and length == (unique | length) and
    all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$"))) and
  (.sandbox | type == "boolean") and
  ((.allow_sandbox_bypass // false) | type == "boolean") and
  (if (.allow_sandbox_bypass // false) then .sandbox else true end);

# $path starts with a label, such as "profile work", followed by the field path.
def config_error($path; $message):
  error($path[0] + ($path[1:] | if length == 0 then "" else
    " $" + (map("[" + tojson + "]") | join("")) end) + ": " + $message);
def config_object($path; $fields):
  if type != "object" then config_error($path; "must be an object")
  else (keys - $fields) as $unknown |
    if ($unknown | length) > 0 then config_error($path + [$unknown[0]]; "unknown field")
    else . end end;
def config_assert($valid; $path; $message):
  if $valid then . else config_error($path; $message) end;
def reference_list: type == "array" and all(.[]; nonempty_control_free_string);

# A profile only selects.
def config_profile($path):
  config_object($path; ["$schema", "hooks", "model", "sandbox", "system", "tools"]) |
  reduce ["hooks", "model", "sandbox", "system", "tools"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | reference_list);
      $path + [$field]; "must be references"));

# A model file configures one request: where it goes and what it carries.
def config_model($path):
  config_object($path; ["$schema", "adapter", "context_window", "endpoint", "request"]) |
  config_assert((has("adapter") | not) or (.adapter | nonempty_control_free_string);
    $path + ["adapter"]; "invalid reference") |
  config_assert((has("endpoint") | not) or (.endpoint | endpoint);
    $path + ["endpoint"]; "must be an HTTP(S) URL") |
  config_assert((has("context_window") | not) or
    (.context_window == null or (.context_window | positive_integer));
    $path + ["context_window"]; "must be null or a positive integer") |
  config_assert((has("request") | not) or (.request | type == "object");
    $path + ["request"]; "must be an object");

# Model files merge left to right: objects recursively, anything else replaced.
# The request override applies last.
def model_merge($models; $request):
  reduce $models[] as $model ({}; . * ($model | del(."$schema"))) |
  .request = ((.request // {}) * $request) |
  if .request.model | model_name then . else
    error("a model is required: set request.model in models/default.jsonc or with --request")
  end |
  if (.adapter // "") == "" then error("a model adapter is required") else . end;

# A sandbox file enables or disables sandboxing and grants extra paths.
def config_sandbox($path):
  config_object($path; ["$schema", "enabled", "read", "write"]) |
  config_assert((has("enabled") | not) or (.enabled | type == "boolean");
    $path + ["enabled"]; "must be a boolean") |
  reduce ["read", "write"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | type == "array");
      $path + [$field]; "must be an array") |
    reduce range(0; .[$field] // [] | length) as $at (.;
      config_assert(.[$field][$at] | stored_reference; $path + [$field, $at];
        "must be a /, ~/, ./, ../, or @ path")));

# A "./" or "../" reference in a config file is relative to the file's $dir.
def relative_to($dir):
  if type == "string" and (startswith("./") or startswith("../")) then
    reduce (($dir + "/" + .) | split("/")[]) as $part ([];
      if $part == "" or $part == "." then . elif $part == ".." then .[:-1]
      else . + [$part] end) | "/" + join("/")
  else . end;
def config_relative($kind; $dir):
  def each($field): if has($field) and (.[$field] | type == "array") then
    .[$field] |= map(relative_to($dir)) else . end;
  if type != "object" then .
  elif $kind == "profile" then each("model") | each("sandbox") | each("system") |
    each("tools") | each("hooks")
  elif $kind == "model" then if has("adapter") then .adapter |= relative_to($dir) else . end
  else each("read") | each("write") end;

# Sandbox files merge left to right: grants accumulate and "enabled" replaces.
def sandbox_merge($files):
  reduce $files[] as $file ({enabled:true, read:[], write:[]};
    (if $file | has("enabled") then .enabled = $file.enabled else . end) |
    .read += ($file.read // []) | .write += ($file.write // []));

# Every path in a frozen profile through f.
def profile_paths(f):
  .model.adapter |= f | .system |= map(f) | .tools |= map(f) |
  .hooks |= map_values(map(f)) |
  .sandbox_read_paths |= map(f) | .sandbox_write_paths |= map(f);

# Stored paths name bundled files "@...", files under HOME "~/...", and
# anything else absolutely. An empty $share stores nothing as bundled.
def store_path($share; $home):
  if $share != "" and startswith($share + "/") then "@" + ltrimstr($share + "/")
  elif $home != "" and startswith($home + "/") then "~" + ltrimstr($home)
  else . end;

def expand_path($share; $home):
  if startswith("@") then
    $share + "/" + ltrimstr("@")
  elif startswith("~/") then
    if $home == "" then error("cannot expand ~ without HOME")
    else $home + ltrimstr("~") end
  else . end;

def profile_store($share; $home): profile_paths(store_path($share; $home));
def profile_expand($share; $home): profile_paths(expand_path($share; $home));

# The frozen profile: the merged model, resolved references with hooks grouped
# by lifecycle, and the session's sandbox grants.
def canonical_profile:
  type == "object" and
  keys == ["hooks", "model", "sandbox", "sandbox_read_paths", "sandbox_write_paths",
    "system", "tools"] and
  (.model | type == "object" and
    (keys - ["context_window"]) == ["adapter", "endpoint", "request"] and
    (.endpoint | endpoint) and (.request | type == "object") and
    (.request.model | model_name) and
    ((has("context_window") | not) or .context_window == null or
      (.context_window | positive_integer))) and
  (.system | type == "array") and (.tools | type == "array") and
  (.hooks | type == "object" and ((keys - hook_names) | length == 0) and
    all(.[]; type == "array")) and
  (.sandbox_read_paths | type == "array") and (.sandbox_write_paths | type == "array") and
  all(.model.adapter, .system[], .tools[], .hooks[][], .sandbox_read_paths[],
    .sandbox_write_paths[]; stored_reference) and
  (.tools | map(split("/") | last) | all(.[]; tool_name) and length == (unique | length)) and
  (.sandbox | type == "boolean");

# The session header freezes one profile. lib/session.jq owns the records that
# follow it, but cannot call canonical_profile across a module boundary.
def canonical_session_header:
  type == "object" and
  keys == ["created", "cwd", "format_version", "profile", "type"] and
  .type == "session" and .format_version == 1 and
  (.cwd | stored_cwd) and (.created | type == "string") and
  (.profile | canonical_profile);

def header_expand($share; $home):
  .cwd |= expand_path(""; $home) | .profile |= profile_expand($share; $home);
