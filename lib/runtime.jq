# The runtime shape, the header that freezes it, and the config that resolves
# it. Display templates are validated and applied here.
#
# jq resolves an included module's internal calls only one level deep, so every
# module states its own vocabulary. The header lives here rather than in
# lib/session.jq because it validates the runtime nested inside it.

def profile_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$");

def tool_name:
  type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$");

def nul_free_string:
  type == "string" and (index("\u0000") | not);

def nonempty_control_free_string:
  type == "string" and length > 0 and (test("[[:cntrl:]]") | not);

def model_name: nonempty_control_free_string;
def absolute_path: type == "string" and startswith("/") and (test("[[:cntrl:]]") | not);
def endpoint: type == "string" and test("^https?://[^[:space:][:cntrl:]]+$");

def positive_integer:
  type == "number" and floor == . and . >= 1 and . <= 2147483647;
def capture_bytes: positive_integer and . >= 64;
def preview_lines:
  . == "full" or (type == "number" and floor == . and . >= 0 and . <= 2147483647);

def component_environment:
  type == "array" and
  all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")) and
  length == (unique | length);

def hook_names:
  ["session_start", "user_prompt_submit", "permission_request", "pre_tool_use",
   "post_tool_use", "stop"];

# Display templates. script_template admits exactly the variables that
# render_component supplies below; read the two together.
def script_template($input_variables; $output):
  type == "string" and (index("\u0000") | not) and
  (gsub("\\$\\{[^{}]+\\}"; "") | index("${") | not) and
  ([scan("\\$\\{([^{}]+)\\}")[0]] | all(.[];
    . == "name" or . == "input" or
    (if $input_variables == null then test("^input\\.[A-Za-z_][A-Za-z0-9_]*$")
     else . as $name | $input_variables | index($name) != null end) or
    ($output and IN("output.stdout", "output.stderr", "output.exit_code"))));

def component_render($input_variables; $permission):
  (["initial_user_text", "model_text", "user_text"] +
    if $permission then ["permission_user_text"] else [] end) as $fields |
  type == "object" and
  (keys - ($fields + ["preview_lines"]) | length) == 0 and
  all(to_entries[] | select(.key != "preview_lines"); . as $entry | .value |
    script_template($input_variables; $entry.key | IN("model_text", "user_text"))) and
  (if has("preview_lines") then .preview_lines | preview_lines else true end);

def complete_component_render($input_variables; $permission):
  (["initial_user_text", "model_text", "user_text"] +
    if $permission then ["permission_user_text"] else [] end) as $fields |
  component_render($input_variables; $permission) and
  (($fields - keys | length) == 0);

def render_value:
  if . == null then ""
  elif type == "string" then .
  else tojson end;

def render_input:
  . as $input |
  {input:($input | render_value)} +
  ($input | if type == "object" then
    with_entries(.key = "input." + .key | .value |= render_value)
  else {} end);

def render_template($template; $variables):
  $template | gsub("\\$\\{(?<name>[^{}]+)\\}"; $variables[.name]);

def render_component($render; $name; $input; $output):
  ({name:$name} + ($input | render_input) + {
    "output.stdout":$output.stdout,
    "output.stderr":$output.stderr,
    "output.exit_code":($output.exit_code | tostring)
  }) as $variables |
  $render |
  with_entries(.value = render_template(.value;$variables)) |
  with_entries(select(.value != ""));

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
  (keys - ["command", "environment", "help", "match", "render"] | length) == 0 and
  has("command") and has("environment") and has("render") and
  (.command | absolute_path) and
  (.render | complete_component_render(null; false)) and
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
  (if has("render") then .render | component_render($input_variables; true)
   else true end) and
  ((.environment // []) | component_environment) and
  (.sandbox | type == "boolean") and
  ((.allow_sandbox_bypass // false) | type == "boolean") and
  (if (.allow_sandbox_bypass // false) then .sandbox else true end);

# The resolved runtime, as it appears at header.runtime.
def canonical_runtime:
  type == "object" and
  (.profile | type == "object" and
    ((keys - ["context_window", "request", "system"]) | length == 0) and
    (["request"] - keys | length == 0) and
    (.request | type == "object" and (.model | model_name)) and
    ((has("system") | not) or
      (.system | type == "array" and all(.[]; absolute_path))) and
    (if has("context_window") then
      .context_window == null or (.context_window | positive_integer)
    else true end)) and
  (.backend | type == "object" and
    ((keys - ["command", "context_window_command", "endpoint", "env_file", "environment", "http_stall", "http_timeout", "insecure_tls", "name"]) | length == 0) and
    (["command", "endpoint", "env_file", "environment", "http_stall", "http_timeout", "insecure_tls", "name"] - keys | length == 0) and
    (.name | profile_name) and (.command | absolute_path) and (.endpoint | endpoint) and
    (.environment | component_environment) and (.insecure_tls | type == "boolean") and
    (.env_file == "" or (.env_file | absolute_path)) and
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
    (.sandbox_read_paths | type == "array" and all(.[]; absolute_path)) and
    (.sandbox_write_paths | type == "array" and all(.[]; absolute_path)) and
    (.fence == "" or (.fence | absolute_path)) and
    (.tools | type == "array" and all(.[];
      type == "object" and keys == ["command", "manifest", "name", "settings"] and
      (.name | tool_name) and (.command | absolute_path) and
      (.settings == null or (.settings | absolute_path)) and
      (.manifest | . as $manifest | tool_manifest and has("render") and
        (.render | complete_component_render(
          ($manifest.input_schema.properties // {} | keys | map("input." + .)); true))) and
      (if .manifest.sandbox then .settings != null else .settings == null end))) and
    (([.tools[].name] | unique | length) == (.tools | length)) and
    (.sandbox | type == "boolean") and
    (.max_requests_per_turn | positive_integer) and
    (.max_tool_calls_per_request | positive_integer) and
    (.max_capture_bytes | capture_bytes));

# The session header freezes one runtime. lib/session.jq owns the records that
# follow it, but cannot call canonical_runtime across a module boundary.
def canonical_session_header($format_version):
  type == "object" and .type == "session" and .format_version == $format_version and
  (.cwd | absolute_path) and (.created | type == "string") and
  (.runtime | canonical_runtime);

def hook_render_defaults:
  {initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"};
def tool_render_defaults:
  {initial_user_text:"${name} ${input}",
   user_text:"${name} ${input}\n${output.stdout}${output.stderr}",
   model_text:"${output.stdout}${output.stderr}",permission_user_text:"${input}"};

def config_error($path; $message):
  error("invalid config at $" + ($path | map("[" + tojson + "]") | join("")) + ": " + $message);
def config_object($path; $fields):
  if type != "object" then config_error($path; "must be an object")
  else (keys - $fields) as $unknown |
    if ($unknown | length) > 0 then config_error($path + [$unknown[0]]; "unknown field")
    else . end end;
def config_assert($valid; $path; $message):
  if $valid then . else config_error($path; $message) end;

def config_theme($path):
  ["text", "muted", "divider", "footer", "prompt", "prompt_waiting",
   "system", "context", "user", "agent", "activity", "link", "code", "tool",
   "reasoning", "error", "syntax_comment", "syntax_keyword", "syntax_string",
   "syntax_number", "syntax_tag", "diff_added", "diff_added_background",
   "diff_removed", "diff_removed_background", "permission"] as $colors |
  config_object($path; $colors) |
  reduce $colors[] as $field (.;
    config_assert((has($field) | not) or (.[$field] | type == "string" and
      test("^#[0-9A-Fa-f]{6}$")); $path + [$field]; "must be a #RRGGBB color"));
def config_backend($path):
  config_object($path; ["adapter", "endpoint", "environment", "insecure_tls",
    "http_timeout", "http_stall"]) |
  config_assert((has("adapter") | not) or (.adapter | nonempty_control_free_string);
    $path + ["adapter"]; "invalid reference") |
  config_assert((has("endpoint") | not) or (.endpoint | endpoint);
    $path + ["endpoint"]; "must be an HTTP(S) URL") |
  config_assert((has("environment") | not) or (.environment | component_environment);
    $path + ["environment"]; "must contain unique environment variable names") |
  config_assert((has("insecure_tls") | not) or (.insecure_tls | type == "boolean");
    $path + ["insecure_tls"]; "must be a boolean") |
  config_assert((has("http_timeout") | not) or (.http_timeout | positive_integer);
    $path + ["http_timeout"]; "must be a positive integer") |
  config_assert((has("http_stall") | not) or (.http_stall | positive_integer);
    $path + ["http_stall"]; "must be a positive integer");
def config_harness($path):
  config_object($path; ["tools", "sandbox", "sandbox_read_paths", "sandbox_write_paths",
    "max_requests_per_turn", "max_tool_calls_per_request", "max_capture_bytes"] + hook_names) |
  reduce hook_names[] as $hook (.;
    config_assert((has($hook) | not) or (.[$hook] | type == "array" and
      all(.[]; nonempty_control_free_string)); $path + [$hook]; "must be references")) |
  config_assert((has("tools") | not) or (.tools | type == "array" and
    all(.[]; nonempty_control_free_string) and length == (unique | length));
    $path + ["tools"]; "must be unique references") |
  config_assert((has("sandbox") | not) or (.sandbox | type == "boolean");
    $path + ["sandbox"]; "must be a boolean") |
  reduce ["sandbox_read_paths", "sandbox_write_paths"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | type == "array" and
      all(.[]; type == "string" and length > 0 and
        (startswith("/") or startswith("~/")) and (contains("\u0000") | not)));
      $path + [$field]; "must contain absolute or ~/ paths")) |
  config_assert((has("max_requests_per_turn") | not) or
    (.max_requests_per_turn | positive_integer); $path + ["max_requests_per_turn"];
    "must be a positive integer") |
  config_assert((has("max_tool_calls_per_request") | not) or
    (.max_tool_calls_per_request | positive_integer); $path + ["max_tool_calls_per_request"];
    "must be a positive integer") |
  config_assert((has("max_capture_bytes") | not) or (.max_capture_bytes | capture_bytes);
    $path + ["max_capture_bytes"]; "must be at least 64");
def config_profile($path):
  config_object($path; ["extend", "backend", "context_window", "harness", "request", "system"]) |
  config_assert((has("extend") | not) or (.extend | profile_name);
    $path + ["extend"]; "invalid profile name") |
  config_assert((has("backend") | not) or (.backend | profile_name);
    $path + ["backend"]; "invalid backend name") |
  config_assert((has("harness") | not) or (.harness | profile_name);
    $path + ["harness"]; "invalid harness name") |
  config_assert((has("context_window") | not) or
    (.context_window == null or (.context_window | positive_integer));
    $path + ["context_window"]; "must be null or a positive integer") |
  config_assert((has("request") | not) or (.request | type == "object");
    $path + ["request"]; "must be an object") |
  config_assert((has("system") | not) or (.system | type == "array" and
    all(.[]; nonempty_control_free_string)); $path + ["system"]; "must be references");

def config_validate:
  config_object([]; ["$schema", "default_profile", "theme_mode", "theme_light", "theme_dark",
    "backends", "harnesses", "themes", "tui", "profiles"]) |
  config_assert((has("$schema") | not) or (."$schema" | type == "string");
    ["$schema"]; "must be a string") |
  config_assert((has("default_profile") | not) or (.default_profile | profile_name);
    ["default_profile"]; "invalid profile name") |
  config_assert((has("theme_mode") | not) or (.theme_mode | IN("auto", "light", "dark"));
    ["theme_mode"]; "invalid theme mode") |
  config_assert((has("theme_light") | not) or (.theme_light | profile_name);
    ["theme_light"]; "invalid theme") |
  config_assert((has("theme_dark") | not) or (.theme_dark | profile_name);
    ["theme_dark"]; "invalid theme") |
  if has("backends") then .backends |= (to_entries | map(.key as $name |
    config_assert($name | profile_name; ["backends", $name]; "invalid name") |
    .value |= config_backend(["backends", $name])) | from_entries) else . end |
  if has("harnesses") then .harnesses |= (to_entries | map(.key as $name |
    config_assert($name | profile_name; ["harnesses", $name]; "invalid name") |
    .value |= config_harness(["harnesses", $name])) | from_entries) else . end |
  if has("themes") then .themes |= (to_entries | map(.key as $name |
    config_assert($name | profile_name; ["themes", $name]; "invalid name") |
    .value |= config_theme(["themes", $name])) | from_entries) else . end |
  if has("tui") then .tui |= (
    ["preview_lines_reasoning", "preview_lines"] as $preview_fields |
    config_object(["tui"]; $preview_fields) |
    reduce $preview_fields[] as $field (.;
      config_assert((has($field) | not) or (.[$field] | preview_lines);
        ["tui", $field]; "must be full or a non-negative integer"))) else . end |
  if has("profiles") then .profiles |= (to_entries | map(.key as $name |
    config_assert($name | profile_name; ["profiles", $name]; "invalid name") |
    .value |= config_profile(["profiles", $name])) | from_entries) else . end;

def config_resolve_profiles($bundled; $configured; $backends; $harnesses):
  def resolve($name; $seen):
    if $seen | index($name) then error("profile inheritance cycle")
    elif $configured | has($name) then
      $configured[$name] as $profile |
      if $profile | has("extend") then
        (if $name == "default" and $profile.extend == "default" then
          $bundled.default // error("unknown bundled default profile")
        else resolve($profile.extend; $seen + [$name]) end) * ($profile | del(.extend))
      else $profile end
    elif $bundled | has($name) then $bundled[$name]
    else error("unknown profile: " + $name) end;
  reduce (($bundled + $configured) | keys[]) as $name ({};
    resolve($name; []) as $profile |
    .[$name] = ($profile |
      if has("backend") then .backend as $ref |
        .backend = (($backends[$ref] // error("unknown backend: " + $ref)) + {name:$ref}) else . end |
      if has("harness") then .harness as $ref |
        .harness = (($harnesses[$ref] // error("unknown harness: " + $ref)) + {name:$ref}) else . end));

def presentation_finish:
  . as $config |
  ([$config.theme_light, $config.theme_dark] | unique | map(. as $name |
    select($config.themes | has($name) | not)) | join(", ")) as $missing |
  if $missing != "" then error("shellfish:unknown-theme:" + $missing)
  else $config end;

def runtime_prepare:
  . as $input |
  $input.defaults as $defaults |
  $input.raw as $raw |
  $input.profile_override as $profile_override |
  $input.model_override as $model_override |
  $input.request_override as $request_override |
  $input.backend_override as $backend_override |
  $input.external_backend_name as $external_backend_name |
  ($raw | config_validate) as $validated |
  ($defaults * $validated) as $base |
  ($base | .profiles = config_resolve_profiles(
    $defaults.profiles; $validated.profiles // {};
    .backends; .harnesses)) as $config |
  (if $profile_override == "" then $config.default_profile else $profile_override end) as $name |
  ($config.profiles[$name] // error("unknown profile: " + $name)) as $selected |
  $selected |
  .harness |= reduce ["sandbox_read_paths", "sandbox_write_paths"][] as $field (.;
    if has($field) then .[$field] |= map(
      if startswith("~/") then
        if $input.home == "" then error("cannot expand ~ without HOME")
        else $input.home + "/" + ltrimstr("~/") end
      else . end)
    else . end) |
  if $backend_override == "" then .
  elif $config.backends | has($backend_override) then
    .backend = ($config.backends[$backend_override] + {name:$backend_override})
  else .backend = {name:$external_backend_name} end |
  . as $profile |
  ($profile.backend.name // error("profile backend is required")) as $backend_name |
  (($profile.request // {}) * $request_override |
    if $model_override == "" then . else .model = $model_override end |
    select(.model | model_name) //
      error("a valid model is required for a new session")) as $request |
  ($backend_override != "" and ($config.backends | has($backend_override) | not)) as $external |
  {
    profile:$profile,
    request:$request,
    backend_name:$backend_name,
    backend_reference:(if $external then $backend_override
      else ($profile.backend.adapter // $backend_name) end),
    backend_external:$external,
    presentation:((($defaults | {theme_mode,theme_light,theme_dark,tui,themes}) *
      ($validated | {theme_mode,theme_light,theme_dark,tui,themes} |
      with_entries(select(.value != null)))) | presentation_finish),
    tool_references:($profile.harness.tools // []),
    system_references:($profile.system // []),
    hook_component_references:[hook_names[] as $hook |
      ($profile.harness[$hook] // [])[] | {hook:$hook,reference:.}]
  };

def presentation_resolve:
  . as {$defaults,$raw} |
  if $raw | type != "object" then error("shellfish:invalid-config")
  else
    ((($defaults | {theme_mode,theme_light,theme_dark,tui,themes}) *
      ($raw | {theme_mode,theme_light,theme_dark,tui,themes} |
      with_entries(select(.value != null))) |
      config_validate) | presentation_finish)
  end;

def runtime_finalize:
  . as $input |
  $input.prepared as $prepared |
  ($input.manifest | fromjson |
    select(type == "object" and keys == ["endpoint", "environment"] and
      (.endpoint | endpoint) and (.environment | component_environment)) //
    error("invalid backend manifest")) as $manifest |
  $input.command as $command |
  $input.resolved as $args |
  ($prepared.tool_references | length) as $tool_count |
  ($prepared.hook_component_references | length) as $component_count |
  ($tool_count * 5) as $component_offset |
  [range(0; $tool_count) as $index |
    ($args[($index * 5):][:5]) |
    {name:.[0],command:.[1],manifest_json:.[2],settings:.[3],
      settings_readable:(.[4] == "1")}] as $resolved_tools |
  [range(0; $component_count) as $index |
    ($args[($component_offset + ($index * 3)):][:3]) |
    {hook:.[0],command:.[1],manifest_json:.[2]}] as $resolved_components |
  [$resolved_tools[] as $tool |
    ($tool.manifest_json | fromjson |
      select(tool_manifest) //
        error("invalid tool manifest: " + $tool.command) |
      .render = (tool_render_defaults + (.render // {}))) as $tool_manifest |
    if $tool_manifest.sandbox and ($tool.settings_readable | not) then
      error("cannot read tool sandbox settings: " + $tool.settings)
    else {name:$tool.name,command:$tool.command,
      manifest:$tool_manifest,
      settings:(if $tool_manifest.sandbox then $tool.settings else null end)} end] as $tools |
  (reduce $resolved_components[] as $component ({};
    ($component.manifest_json | fromjson) as $manifest |
    (hook_render_defaults + ($manifest.render // {})) as $render |
    ($manifest |
      select(type == "object" and
        (keys - (if $component.hook == "user_prompt_submit"
          then ["environment", "help", "match", "render"]
          else ["environment", "render"] end) | length) == 0 and
        ((.environment // []) | component_environment) and
        (if $manifest | has("render") then
           $manifest.render | component_render(null; false)
         else true end) and
        (if has("match") then .match | hook_match else true end) and
        (if has("help") then
           has("match") and (.help | hook_help)
         else true end)) //
      error("invalid hook manifest: " + $component.command)) as $hook_manifest |
    .[$component.hook] += [({command:$component.command,render:$render,
      environment:($hook_manifest.environment // [])} +
      (if $hook_manifest | has("match") then {match:$hook_manifest.match} else {} end) +
      (if $hook_manifest | has("help") then {help:$hook_manifest.help} else {} end))])) as $hooks |
  $prepared.profile as $profile |
  ((if $profile.harness | has("sandbox") then $profile.harness.sandbox else true end) and
    any($tools[]; .manifest.sandbox)) as $needs_fence |
  if $needs_fence and $input.fence == "" then error("sandboxing requires fence") else . end |
  {
    profile:({request:$prepared.request,system:$input.system} +
      (if $profile | has("context_window") then
        {context_window:$profile.context_window} else {} end)),
    backend:{name:$prepared.backend_name,command:$command,env_file:$input.env_file,
      endpoint:($profile.backend.endpoint // $manifest.endpoint),
      environment:($profile.backend.environment // $manifest.environment),
      insecure_tls:($profile.backend.insecure_tls // false),
      http_timeout:($profile.backend.http_timeout // 3600),
      http_stall:($profile.backend.http_stall // 300)} +
      (if $input.context_window_command == "" then {}
       else {context_window_command:$input.context_window_command} end),
    harness:({
      sandbox_read_paths:(($profile.harness.sandbox_read_paths // []) + $input.sandbox_read_paths),
      sandbox_write_paths:(($profile.harness.sandbox_write_paths // []) + $input.sandbox_write_paths),
      fence:(if $needs_fence then $input.fence else "" end),tools:$tools,
      sandbox:(if $profile.harness | has("sandbox")
        then $profile.harness.sandbox else true end),
      max_requests_per_turn:($profile.harness.max_requests_per_turn // 100),
      max_tool_calls_per_request:($profile.harness.max_tool_calls_per_request // 25),
      max_capture_bytes:($profile.harness.max_capture_bytes // 32768)} + $hooks)
  };
