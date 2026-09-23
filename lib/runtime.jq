# The runtime shape, the header that freezes it, and the config that resolves
# it. Tool display templates are validated and applied here. The header lives here
# rather than in lib/session.jq because it validates the runtime nested inside it.
#
# Repeated primitives are deliberate; see AGENTS.md.

def profile_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$");

def tool_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");

def nul_free_string:
  type == "string" and (index("\u0000") | not);

def nonempty_control_free_string:
  type == "string" and length > 0 and (test("[[:cntrl:]]") | not);

def model_name: nonempty_control_free_string;
def stored_path:
  nonempty_control_free_string and
  (startswith("/") or . == "." or startswith("./") or . == "~" or startswith("~/"));
def stored_cwd:
  nonempty_control_free_string and (startswith("/") or . == "~" or startswith("~/"));
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

# Each lifecycle lists its hook scripts nearest first: the first runs, and each
# later one is the parent of the one before.
def harness_hooks:
  . as $harness |
  all(hook_names[]; ($harness[.] // []) | type == "array" and all(.[]; stored_path));

def tool_manifest:
  (.input_schema.properties // {} | keys | map("input." + .)) as $input_variables |
  type == "object" and
  ((keys - ["allow_sandbox_bypass", "description", "environment",
    "input_schema", "sandbox", "user_draft", "user_permission"]) | length == 0) and
  (.description | nul_free_string and length > 0) and
  (.input_schema | type == "object" and .type == "object" and
    ((.properties // {}) | type == "object") and
    ((.required // []) | type == "array" and all(.[]; type == "string") and
      length == (unique | length)) and
    ((.properties // {}) |
      has("request_sandbox_bypass") or has("sandbox_bypass_reason") | not) and
    ((.required // []) |
      index("request_sandbox_bypass") == null and index("sandbox_bypass_reason") == null)) and
  all(.user_draft, .user_permission; . == null or tool_template($input_variables)) and
  ((.environment // []) | component_environment) and
  (.sandbox | type == "boolean") and
  ((.allow_sandbox_bypass // false) | type == "boolean") and
  (if (.allow_sandbox_bypass // false) then .sandbox else true end);

# The runtime stored in the session header.
def canonical_runtime:
  type == "object" and
  ((keys - ["backend", "context_window", "harness", "request", "system"]) | length == 0) and
  ((["backend", "harness", "request", "system"] - keys) | length == 0) and
  (.request | type == "object" and (.model | model_name)) and
  (.system | type == "array" and all(.[]; stored_path)) and
  (if has("context_window") then
    .context_window == null or (.context_window | positive_integer)
  else true end) and
  (.backend | type == "object" and
    keys == ["command", "endpoint", "http_stall", "http_timeout", "insecure_tls"] and
    (.command | stored_path) and (.endpoint | endpoint) and
    (.insecure_tls | type == "boolean") and
    (.http_timeout | positive_integer) and (.http_stall | positive_integer)) and
  (.harness | type == "object" and
    (["sandbox_read_paths", "sandbox_write_paths",
      "max_capture_bytes", "max_requests_per_turn",
      "max_tool_calls_per_request", "sandbox", "tools"] as $required |
      ((keys - ($required + hook_names)) | length == 0) and
      (($required - keys) | length == 0)) and
    harness_hooks and
    (.sandbox_read_paths | type == "array" and all(.[]; stored_path)) and
    (.sandbox_write_paths | type == "array" and all(.[]; stored_path)) and
    (.tools | type == "array" and all(.[];
      type == "object" and keys == ["command", "manifest", "name", "settings"] and
      (.name | tool_name) and (.command | stored_path) and
      (.settings == null or (.settings | stored_path)) and
      (.manifest | tool_manifest) and
      (if .manifest.sandbox then .settings != null else .settings == null end))) and
    (([.tools[].name] | unique | length) == (.tools | length)) and
    (.sandbox | type == "boolean") and
    (.max_requests_per_turn | positive_integer) and
    (.max_tool_calls_per_request | positive_integer) and
    (.max_capture_bytes | capture_bytes));

# The session header freezes one runtime. lib/session.jq owns the records that
# follow it, but cannot call canonical_runtime across a module boundary.
def canonical_session_header:
  type == "object" and
  keys == ["created", "cwd", "format_version", "runtime", "type"] and
  .type == "session" and .format_version == 1 and
  (.cwd | stored_cwd) and (.created | type == "string") and
  (.runtime | canonical_runtime);

def runtime_paths(rewrite):
  .system |= map(rewrite) |
  .backend.command |= rewrite |
  .harness.sandbox_read_paths |= map(rewrite) |
  .harness.sandbox_write_paths |= map(rewrite) |
  .harness.tools |= map(.command |= rewrite |
    (if .settings == null then . else .settings |= rewrite end)) |
  reduce hook_names[] as $hook (.;
    if .harness | has($hook) then .harness[$hook] |= map(rewrite) else . end);

def expand_path($cwd; $home):
  if startswith("/") then .
  elif . == "~" or startswith("~/") then
    if $home == "" then error("cannot expand ~ without HOME")
    elif . == "~" then $home
    else $home + "/" + ltrimstr("~/") end
  elif . == "." then $cwd
  else $cwd + "/" + ltrimstr("./") end;

def store_path($cwd; $home):
  if $cwd != "" and . == $cwd then "."
  elif $cwd != "" and startswith($cwd + "/") then "./" + ltrimstr($cwd + "/")
  elif $home != "" and . == $home then "~"
  elif $home != "" and startswith($home + "/") then "~/" + ltrimstr($home + "/")
  else . end;

def header_expand($home):
  (.cwd | expand_path(""; $home)) as $cwd |
  .cwd = $cwd | .runtime |= runtime_paths(expand_path($cwd; $home));

def header_store($home):
  .cwd as $cwd |
  .cwd = ($cwd | store_path(""; $home)) |
  .runtime |= runtime_paths(store_path($cwd; $home));

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

# One profile file. Its top level is the runtime top level, so "backend" and
# "hooks" are inline objects rather than names into separate maps.
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

# A folder holding hooks/LIFECYCLE contributes [that script, "..."] unless its
# profile sets the list. $scripts are the executables found under hooks/.
def profile_discover($scripts):
  with_entries((.key | rtrimstr("profile.jsonc") + "hooks/") as $hooks |
    .value |= reduce hook_names[] as $hook (.;
      if ($scripts | index([$hooks + $hook])) and type == "object" and
          ((.hooks // {}) | type == "object" and (has($hook) | not))
      then .hooks[$hook] = [$hooks + $hook, "..."] else . end));

# Profile files keyed by path become their folder names: bundled folders are
# "@NAME" and configured folders "NAME".
def profile_map($bundled):
  with_entries(.key |= ((if startswith($bundled + "/") then "@" else "" end) +
    (split("/")[-2])));

# A bare name prefers the configured folder; "@NAME" is always the bundled one.
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

def profile_select($profiles; $names; $model; $request; $backend; $home):
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
  reduce ["sandbox_read_paths", "sandbox_write_paths"][] as $field (.;
    if has($field) then .[$field] |= map(
      if startswith("~/") then
        if $home == "" then error("cannot expand ~ without HOME")
        else $home + "/" + ltrimstr("~/") end
      else . end)
    else . end);

# Filesystem facts jq cannot obtain, keyed by "<kind>TAB<reference>". Each entry
# is a resolved path, one flag for readable tool sandbox settings, and the
# component manifest.
def resolution_table($words):
  [range(0; $words | length; 4) as $at |
    {key:$words[$at], value:{path:$words[$at + 1],
      flag:($words[$at + 2] == "1"), manifest:($words[$at + 3] | fromjson)}}] |
  from_entries;

def runtime_finalize($profile; $table; $grants):
  $table["backend"] as $backend |
  ($backend.manifest |
    select(type == "object" and keys == ["endpoint"] and (.endpoint | endpoint)) //
    error("invalid backend manifest")) as $manifest |
  [($profile.tools // [])[] as $reference |
    $table["tools\t" + $reference] as $entry |
    ($entry.manifest | select(tool_manifest) //
        error("invalid tool manifest: " + $entry.path)) as $tool_manifest |
    if $tool_manifest.sandbox and ($entry.flag | not) then
      error("cannot read tool sandbox settings: " + $entry.path + "/fence.jsonc")
    else {name:($entry.path | split("/") | last), command:($entry.path + "/run"),
      manifest:$tool_manifest,
      settings:(if $tool_manifest.sandbox then $entry.path + "/fence.jsonc"
        else null end)} end] as $tools |
  (reduce hook_names[] as $hook ({};
    ($profile.hooks[$hook] // []) as $references |
    if $references == [] then .
    else .[$hook] = [$references[] | $table["hooks\t" + .].path] end)) as $hooks |
  {
    backend:{command:($backend.path + "/run"),
      endpoint:($profile.backend.endpoint // $manifest.endpoint),
      insecure_tls:($profile.backend.insecure_tls // false),
      http_timeout:($profile.backend.http_timeout // 3600),
      http_stall:($profile.backend.http_stall // 300)},
    harness:({
      sandbox_read_paths:(($profile.sandbox_read_paths // []) + $grants.sandbox_read_paths),
      sandbox_write_paths:(($profile.sandbox_write_paths // []) + $grants.sandbox_write_paths),
      tools:$tools,
      sandbox:($profile.sandbox != false),
      max_requests_per_turn:($profile.max_requests_per_turn // 100),
      max_tool_calls_per_request:($profile.max_tool_calls_per_request // 25),
      max_capture_bytes:($profile.max_capture_bytes // 32768)} + $hooks),
    request:$profile.request,
    system:[($profile.system // [])[] | $table["system\t" + .].path]
  } +
  (if $profile | has("context_window") then
    {context_window:$profile.context_window} else {} end);
