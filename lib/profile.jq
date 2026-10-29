# Profiles and model files, the session header that freezes their resolution,
# and component manifests and their templates. The header lives here rather
# than in lib/session.jq because it validates the profile and model inside it.
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

# A template names the input, its declared properties, and the output streams.
def component_template($fields):
  nul_free_string and
  ([scan("\\$\\{([^{}]*)\\}")[0]] - ["input", "output.stdout", "output.stderr"] - $fields |
    length == 0);

# $values holds input and output. A placeholder names one key below input or
# output, taken literally even when it contains dots. Strings substitute as-is,
# null as nothing, and other values as JSON. An absent template renders empty.
def render_template($template; $values):
  $template // "" | gsub("\\$\\{(?<path>[^{}]+)\\}"; .path as $path | $values |
    getpath($path | index(".") as $dot |
      if $dot == null then [$path] else [$path[:$dot], $path[$dot + 1:]] end) |
    if type == "string" then . elif . == null then "" else tojson end);

# Shared presentation with caller-supplied keys and template fields.
def component_manifest($attrs; $fields):
  type == "object" and
  ((keys - ["user_text", "user_preview_lines", "max_capture_bytes"] - $attrs) | length == 0) and
  (.user_text == null or (.user_text | component_template($fields))) and
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
  component_manifest(["allow_sandbox_bypass", "description", "environment", "input_schema",
    "sandbox"]; .input_schema.properties // {} | keys | map("input." + .)) and
  (.description | nul_free_string and length > 0) and
  (.input_schema | type == "object" and .type == "object" and
    ((.properties // {}) | type == "object") and
    ((.required // []) | type == "array" and all(.[]; type == "string") and
      length == (unique | length)) and
    ((.properties // {}) |
      has("request_sandbox_bypass") or has("sandbox_bypass_reason") | not) and
    ((.required // []) |
      index("request_sandbox_bypass") == null and index("sandbox_bypass_reason") == null)) and
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
# A path: "/", "~/", "./", "../", or "@" for the bundled root.
def path_reference:
  nonempty_control_free_string and test("^(/|~/|\\./|\\.\\./|@)");

# A model file configures one request: where it goes and what it carries.
def config_model($path):
  config_object($path; ["$schema", "adapter", "config", "context_window", "endpoint", "request"]) |
  config_assert((has("config") | not) or (.config | type == "object");
    $path + ["config"]; "must be an object") |
  config_assert((has("adapter") | not) or (.adapter | nonempty_control_free_string);
    $path + ["adapter"]; "invalid reference") |
  config_assert((has("endpoint") | not) or (.endpoint | endpoint);
    $path + ["endpoint"]; "must be an HTTP(S) URL") |
  config_assert((has("context_window") | not) or
    (.context_window == null or (.context_window | positive_integer));
    $path + ["context_window"]; "must be null or a positive integer") |
  config_assert((has("request") | not) or (.request | type == "object");
    $path + ["request"]; "must be an object");

# A sandbox file enables or disables sandboxing, grants extra paths, and limits
# how long a bypass waits for the user.
def config_sandbox($path):
  config_object($path; ["$schema", "enabled", "read", "write", "user_approval_timeout"]) |
  config_assert((has("enabled") | not) or (.enabled | type == "boolean");
    $path + ["enabled"]; "must be a boolean") |
  config_assert((has("user_approval_timeout") | not) or (.user_approval_timeout | positive_integer);
    $path + ["user_approval_timeout"]; "must be a positive integer") |
  reduce ["read", "write"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | type == "array");
      $path + [$field]; "must be an array") |
    reduce range(0; .[$field] // [] | length) as $at (.;
      config_assert(.[$field][$at] | path_reference; $path + [$field, $at];
        "must be a /, ~/, ./, ../, or @ path")));

# A profile selects components and holds opaque configuration. Its lists contain
# references, with inline values also allowed for sandbox and system. Absent
# lists are empty, and a lone sandbox item needs no list. Options add a model list.
def profile_fields: ["sandbox", "system", "tools", "hooks"];
def config_profile($path; $fields):
  config_object($path; ["$schema", "config"] + $fields) |
  del(."$schema") |
  config_assert((has("config") | not) or (.config | type == "object");
    $path + ["config"]; "must be an object") |
  reduce ("model", "sandbox") as $field (.;
    if has($field) and (.[$field] | type != "array") then .[$field] |= [.] else . end) |
  reduce $fields[] as $field (.;
    .[$field] //= [] |
    config_assert(.[$field] | type == "array"; $path + [$field]; "must be a list") |
    reduce range(0; .[$field] | length) as $at (.; ($path + [$field, $at]) as $item |
      .[$field][$at] |= (
        if nonempty_control_free_string then .
        elif $field == "model" then config_model($item)
        elif $field == "sandbox" then config_sandbox($item)
        elif $field == "system" and type == "object" and keys == ["text"] and
          (.text | nul_free_string) then .
        else config_error($item; "must be a reference" +
          if $field == "system" then " or {\"text\": ...}"
          elif $field == "model" or $field == "sandbox" then " or object" else "" end)
        end)));
def config_profile($path): config_profile($path; profile_fields);

# A "./" or "../" reference in a config file is relative to the file's $dir.
def relative_to($dir):
  if type == "string" and (startswith("./") or startswith("../")) then
    reduce (($dir + "/" + .) | split("/")[]) as $part ([];
      if $part == "" or $part == "." then . elif $part == ".." then .[:-1]
      else . + [$part] end) | "/" + join("/")
  else . end;
def config_relative($kind; $dir):
  def each($field; f): if has($field) then .[$field] |= f else . end;
  if $kind == "model" then each("adapter"; relative_to($dir))
  elif $kind == "sandbox" then each("read"; map(relative_to($dir))) |
    each("write"; map(relative_to($dir)))
  else reduce ("model", "sandbox", "system", "tools", "hooks") as $field (.;
    each($field; map(if type == "object" and $field != "system"
      then config_relative($field; $dir) else relative_to($dir) end))) end;

# Model items merge left to right: objects recursively, anything else replaced.
def model_merge($models):
  reduce $models[] as $model ({}; . * ($model | del(."$schema"))) |
  if .request.model | model_name then . else
    error("a model is required: set request.model")
  end |
  if (.adapter // "") == "" then error("a model adapter is required") else . end;

# Sandbox items merge left to right: grants accumulate and settings replace.
def sandbox_merge($files):
  reduce $files[] as $file ({enabled:true, read:[], write:[]};
    . + ($file | with_entries(select(.key | IN("enabled", "user_approval_timeout")))) |
    .read += ($file.read // []) | .write += ($file.write // []));

# Every path in a frozen profile through f.
def header_paths(f):
  .model.adapter |= f | .profile |= (.tools |= map(f) | .hooks |= map(f) |
    .sandbox.read |= map(f) | .sandbox.write |= map(f));

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

# A frozen model is a resolved model file: every field merged and the adapter
# a stored path.
def canonical_model:
  type == "object" and
  (keys - ["config", "context_window"]) == ["adapter", "endpoint", "request"] and
  ((has("config") | not) or (.config | type == "object")) and
  (.adapter | stored_reference) and
  (.endpoint | endpoint) and (.request | type == "object") and
  (.request.model | model_name) and
  ((has("context_window") | not) or .context_window == null or
    (.context_window | positive_integer));

# A frozen profile is a resolved profile: one merged sandbox item, the system
# prompt as at most one text, and every reference a stored path. Resolving it
# again changes nothing.
def canonical_profile:
  type == "object" and
  (keys - ["config"]) == ["hooks", "sandbox", "system", "tools"] and
  ((has("config") | not) or (.config | type == "object")) and
  (.sandbox | type == "object" and
    (keys - ["user_approval_timeout"]) == ["enabled", "read", "write"] and
    (.enabled | type == "boolean") and (.read | type == "array") and
    (.write | type == "array") and
    ((has("user_approval_timeout") | not) or (.user_approval_timeout | positive_integer))) and
  (.system | type == "array" and length <= 1 and all(.[]; type == "object" and
    keys == ["text"] and (.text | nul_free_string) and .text != "")) and
  (.tools | type == "array") and (.hooks | type == "array") and
  all(.tools[], .hooks[], .sandbox.read[], .sandbox.write[]; stored_reference) and
  (.tools | map(split("/") | last) | all(.[]; tool_name) and length == (unique | length));

# The session header freezes one profile and one model. lib/session.jq owns the
# records that follow it, but cannot call canonical_profile across a module
# boundary.
def canonical_session_header:
  type == "object" and
  keys == ["created", "cwd", "format_version", "model", "profile", "type"] and
  .type == "session" and .format_version == 1 and
  (.cwd | stored_cwd) and (.created | type == "string") and
  (.profile | canonical_profile) and (.model | canonical_model);

# Store or expand the paths of an object holding profile and model. Expansion
# also covers a full header's cwd, which creation stores itself.
def header_store($share; $home): header_paths(store_path($share; $home));
def header_expand($share; $home):
  if has("cwd") then .cwd |= expand_path(""; $home) else . end |
  header_paths(expand_path($share; $home));
