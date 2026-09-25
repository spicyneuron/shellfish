# Profiles: the config that resolves one, the session header that freezes it,
# and tool manifests and their templates. The header lives here rather than in
# lib/session.jq because it validates the profile nested inside it.
#
# Repeated primitives are deliberate; see AGENTS.md.

def profile_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$");

def tool_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");

def nul_free_string:
  type == "string" and (index("\u0000") | not);

def nonempty_control_free_string:
  type == "string" and length > 0 and (test("[[:cntrl:]]") | not);

def model_name: nonempty_control_free_string;
def stored_reference:
  nonempty_control_free_string and
  (startswith("/") or startswith("~/") or test("^@(system|tools|hooks|backends)/.+"));
def stored_cwd:
  nonempty_control_free_string and (startswith("/") or startswith("~/"));
def endpoint: type == "string" and test("^https?://[^[:space:][:cntrl:]]+$");

def positive_integer:
  type == "number" and floor == . and . >= 1 and . <= 2147483647;
def capture_bytes: positive_integer and . >= 64;

def component_environment:
  type == "array" and
  all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")) and
  length == (unique | length);

def hook_names:
  ["session_start", "user_prompt_submit", "permission_request", "pre_tool_use",
   "post_tool_use", "stop"];

# A tool template may name only ${name}, ${input}, and ${input.FIELD} for a
# declared input property.
def tool_template($fields):
  type == "string" and (index("\u0000") | not) and
  (gsub("\\$\\{[^{}]+\\}"; "") | index("${") | not) and
  ([scan("\\$\\{([^{}]+)\\}")[0]] |
    all(.[]; IN("name", "input") or (. as $field | $fields | index($field) != null)));

# A call's input is an object; strings substitute as-is, null as nothing, and
# other values as JSON.
def render_template($template; $name; $input):
  def text: if type == "string" then . elif . == null then "" else tojson end;
  ({name:$name, input:($input | text)} +
    ($input | with_entries(.key = "input." + .key | .value |= text))) as $variables |
  $template | gsub("\\$\\{(?<name>[^{}]+)\\}"; $variables[.name] // "");

def tool_manifest:
  (.input_schema.properties // {} | keys | map("input." + .)) as $input_variables |
  type == "object" and
  ((keys - ["allow_sandbox_bypass", "description", "environment",
    "input_schema", "sandbox", "user_permission", "user_text"]) | length == 0) and
  (.description | nul_free_string and length > 0) and
  (.input_schema | type == "object" and .type == "object" and
    ((.properties // {}) | type == "object") and
    ((.required // []) | type == "array" and all(.[]; type == "string") and
      length == (unique | length)) and
    ((.properties // {}) |
      has("request_sandbox_bypass") or has("sandbox_bypass_reason") | not) and
    ((.required // []) |
      index("request_sandbox_bypass") == null and index("sandbox_bypass_reason") == null)) and
  all(.user_permission, .user_text; . == null or tool_template($input_variables)) and
  ((.environment // []) | component_environment) and
  (.sandbox | type == "boolean") and
  ((.allow_sandbox_bypass // false) | type == "boolean") and
  (if (.allow_sandbox_bypass // false) then .sandbox else true end);

def config_error($path; $message):
  error("invalid profile at $" + ($path | map("[" + tojson + "]") | join("")) + ": " + $message);
def config_object($path; $fields):
  if type != "object" then config_error($path; "must be an object")
  else (keys - $fields) as $unknown |
    if ($unknown | length) > 0 then config_error($path + [$unknown[0]]; "unknown field")
    else . end end;
def config_assert($valid; $path; $message):
  if $valid then . else config_error($path; $message) end;
def reference_list: type == "array" and all(.[]; nonempty_control_free_string);

# One profile file. "backend" and "hooks" are inline objects rather than names
# into separate maps.
def config_profile($path):
  config_object($path; ["$schema", "backend", "context_window", "extend", "hooks",
    "max_capture_bytes", "max_requests_per_turn", "max_tool_calls_per_request",
    "request", "sandbox", "sandbox_read_paths", "sandbox_write_paths", "system", "tools"]) |
  config_assert((has("extend") | not) or (.extend | type == "array" and
    all(.[]; ltrimstr("@") | profile_name)); $path + ["extend"]; "must be profile names") |
  config_assert((has("context_window") | not) or
    (.context_window == null or (.context_window | positive_integer));
    $path + ["context_window"]; "must be null or a positive integer") |
  config_assert((has("request") | not) or (.request | type == "object");
    $path + ["request"]; "must be an object") |
  reduce ["system", "tools"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | reference_list);
      $path + [$field]; "must be references")) |
  (if has("backend") then .backend |= (
    config_object($path + ["backend"]; ["adapter", "endpoint",
      "insecure_tls", "http_timeout", "http_stall"]) |
    config_assert((has("adapter") | not) or (.adapter | nonempty_control_free_string);
      $path + ["backend", "adapter"]; "invalid reference") |
    config_assert((has("endpoint") | not) or (.endpoint | endpoint);
      $path + ["backend", "endpoint"]; "must be an HTTP(S) URL") |
    config_assert((has("insecure_tls") | not) or (.insecure_tls | type == "boolean");
      $path + ["backend", "insecure_tls"]; "must be a boolean") |
    reduce ["http_timeout", "http_stall"][] as $field (.;
      config_assert((has($field) | not) or (.[$field] | positive_integer);
        $path + ["backend", $field]; "must be a positive integer"))
  ) else . end) |
  (if has("hooks") then .hooks |= (
    config_object($path + ["hooks"]; hook_names) |
    reduce hook_names[] as $field (.;
      config_assert((has($field) | not) or (.[$field] | reference_list);
        $path + ["hooks", $field]; "must be references"))
  ) else . end) |
  config_assert((has("sandbox") | not) or (.sandbox | type == "boolean");
    $path + ["sandbox"]; "must be a boolean") |
  reduce ["sandbox_read_paths", "sandbox_write_paths"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | type == "array" and
      all(.[]; type == "string" and length > 0 and
        (startswith("/") or startswith("~/")) and (contains("\u0000") | not)));
      $path + [$field]; "must contain absolute or ~/ paths")) |
  reduce ["max_requests_per_turn", "max_tool_calls_per_request"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | positive_integer);
      $path + [$field]; "must be a positive integer")) |
  config_assert((has("max_capture_bytes") | not) or (.max_capture_bytes | capture_bytes);
    $path + ["max_capture_bytes"]; "must be at least 64");

# Profile files keyed by path become their names relative to the profile root.
def profile_map($bundled; $configured):
  with_entries(.key |= (if startswith($bundled + "/") then
      "@" + ltrimstr($bundled + "/")
    else ltrimstr($configured + "/") end |
    rtrimstr(".jsonc")));

# An unprefixed name prefers the configured folder; "@NAME" uses the bundled one.
def profile_key($profiles):
  if startswith("@") or $profiles[.] then . else "@" + . end;

# Objects merge recursively and arrays replace, except that "..." splices the
# inherited array at its position.
def merge_over($base):
  if type == "object" then
    . as $over | (($base | objects) // {}) as $base |
    reduce keys_unsorted[] as $key ($base;
      .[$key] = ($over[$key] | merge_over($base[$key])))
  elif type == "array" then
    [.[] | if . == "..." then (($base | arrays) // [])[] else . end]
  else . end;

# Depth-first with parents first, each profile once. $seen is the ancestor
# path, so diamonds are legal and cycles are not.
def profile_order($profiles; $names; $seen):
  reduce $names[] as $name (.;
    ($name | profile_key($profiles)) as $key |
    if $seen | index([$key]) then error("profile inheritance cycle: " + $name)
    elif index([$key]) then .
    else ($profiles[$key] // error("unknown profile: " + $name) |
        config_profile([$name]) | .extend // []) as $parents |
      profile_order($profiles; $parents; $seen + [$key]) + [$key] end);

# Selected profiles merge in one ordered pass, as if one profile extended them all.
def profile_resolve($profiles; $names):
  reduce ([] | profile_order($profiles; $names; []))[] as $key ({};
    . as $inherited | $profiles[$key] | del(.extend, ."$schema") | merge_over($inherited));

def profile_select($profiles; $names; $model; $request; $backend):
  profile_resolve($profiles; $names) |
  (if $backend == "" then . else .backend.adapter = $backend end) |
  .request = ((.request // {}) * $request |
    if $model == "" then . else .model = $model end) |
  (if .request.model | model_name then . else
    error("a valid model is required for a new session") end) |
  (if (.backend.adapter // "") == "" then
    error("profile backend is required") else . end) |
  # Splicing an inherited list makes a restated tool easy to duplicate.
  ((.tools // []) as $tools |
    if ($tools | length) == ($tools | unique | length) then .
    else error("profile tools must be unique: " + ($tools | join(", "))) end) |
  {system:[], tools:[], hooks:{}, sandbox:true, sandbox_read_paths:[],
   sandbox_write_paths:[], max_requests_per_turn:100, max_tool_calls_per_request:25,
   max_capture_bytes:32768,
   backend:{insecure_tls:false, http_timeout:3600, http_stall:300}} * .;

# Each reference as [kind, reference] through f.
def profile_references(f):
  .backend.adapter |= (["backends", .] | f) |
  .system |= map(["system", .] | f) |
  .tools |= map(["tools", .] | f) |
  .hooks |= map_values(map(["hooks", .] | f));

def profile_paths(reference; path):
  profile_references(.[1] | reference) |
  .sandbox_read_paths |= map(path) | .sandbox_write_paths |= map(path);

# Stored paths name bundled files "@KIND/...", files under HOME "~/...", and
# anything else absolutely.
def store_path($share; $home):
  if $share != "" and startswith($share + "/") then
    if startswith($share + "/system/") or startswith($share + "/tools/") or
        startswith($share + "/hooks/") or startswith($share + "/backends/") then
      "@" + ltrimstr($share + "/")
    else . end
  elif $home != "" and startswith($home + "/") then "~" + ltrimstr($home)
  else . end;

def expand_path($share; $home):
  if startswith("@") then
    $share + "/" + ltrimstr("@")
  elif startswith("~/") then
    if $home == "" then error("cannot expand ~ without HOME")
    else $home + ltrimstr("~") end
  else . end;

def profile_store($share; $home):
  profile_paths(store_path($share; $home); store_path(""; $home));

def profile_expand($share; $home):
  profile_paths(expand_path($share; $home); expand_path(""; $home));

# A session profile is a valid profile with every default filled and every
# reference resolved.
def canonical_profile:
  (try (config_profile([]) | true) catch false) and
  (keys - ["context_window"]) == ["backend", "hooks", "max_capture_bytes",
    "max_requests_per_turn", "max_tool_calls_per_request", "request", "sandbox",
    "sandbox_read_paths", "sandbox_write_paths", "system", "tools"] and
  (.backend | keys == ["adapter", "endpoint", "http_stall", "http_timeout", "insecure_tls"]) and
  (.request.model | model_name) and
  all(.backend.adapter, .system[], .tools[], .hooks[][]; stored_reference) and
  (.tools | map(split("/") | last) | all(.[]; tool_name) and length == (unique | length));

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
