include "lib/runtime/schema";

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
  ["text", "muted", "divider", "footer", "prompt", "system_heading", "context",
   "user_heading", "agent_heading", "tool", "reasoning", "error", "syntax_comment",
   "syntax_keyword", "syntax_string", "syntax_number", "syntax_tag", "diff_added",
   "diff_added_background", "diff_removed", "diff_removed_background", "permission"] as $colors |
  config_object($path; $colors) |
  reduce $colors[] as $field (.;
    config_assert((has($field) | not) or (.[$field] | type == "string" and
      test("^#[0-9A-Fa-f]{6}$")); $path + [$field]; "must be a #RRGGBB color"));
def config_backend($path):
  config_object($path; ["adapter", "endpoint", "api_key_env", "insecure_tls",
    "http_timeout", "http_stall"]) |
  config_assert((has("adapter") | not) or (.adapter | nonempty_control_free_string);
    $path + ["adapter"]; "invalid reference") |
  config_assert((has("endpoint") | not) or (.endpoint | endpoint);
    $path + ["endpoint"]; "must be an HTTP(S) URL") |
  config_assert((has("api_key_env") | not) or (.api_key_env | api_key_env);
    $path + ["api_key_env"]; "invalid credential variable") |
  config_assert((has("insecure_tls") | not) or (.insecure_tls | type == "boolean");
    $path + ["insecure_tls"]; "must be a boolean") |
  config_assert((has("http_timeout") | not) or (.http_timeout | positive_integer);
    $path + ["http_timeout"]; "must be a positive integer") |
  config_assert((has("http_stall") | not) or (.http_stall | positive_integer);
    $path + ["http_stall"]; "must be a positive integer");
def config_harness($path):
  config_object($path; harness_fields + hook_names) |
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
  config_object($path; ["extend"] + profile_fields) |
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
    ["preview_lines_reasoning", "preview_lines_context", "preview_lines_tool_call",
      "preview_lines_tool_result"] as $preview_fields |
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
    select(backend_manifest) // error("invalid backend manifest")) as $manifest |
  $input.command as $command |
  $input.resolved as $args |
  ($prepared.tool_references | length) as $tool_count |
  ($prepared.system_references | length) as $system_count |
  ($prepared.hook_component_references | length) as $component_count |
  ($tool_count * 4) as $system_offset |
  ($system_offset + $system_count) as $component_offset |
  [range(0; $tool_count) as $index |
    ($args[($index * 4):][:4]) |
    {name:.[0],command:.[1],manifest_json:.[2],settings:.[3]}] as $resolved_tools |
  ($args[$system_offset:][:$system_count]) as $system |
  [range(0; $component_count) as $index |
    ($args[($component_offset + ($index * 2)):][:2]) |
    {hook:.[0],path:.[1]}] as $resolved_components |
  [$resolved_tools[] as $tool |
    ($tool.manifest_json | fromjson |
      select(tool_manifest) //
        error("invalid tool manifest: " + $tool.command)) as $tool_manifest |
    if $tool_manifest.sandbox and $tool.settings == "" then
      error("missing tool sandbox settings: " + $tool.command)
    elif ($tool_manifest.sandbox | not) and $tool.settings != "" then
      error("unexpected tool sandbox settings: " + $tool.command)
    else {name:$tool.name,command:$tool.command,
      manifest:$tool_manifest,
      settings:(if $tool.settings == "" then null else $tool.settings end)} end] as $tools |
  (reduce $resolved_components[] as $component ({};
    .[$component.hook] += [$component.path])) as $hooks |
  $prepared.profile as $profile |
  ({
    profile:({request:$prepared.request,system:$system} +
      (if $profile | has("context_window") then
        {context_window:$profile.context_window} else {} end)),
    backend:{name:$prepared.backend_name,command:$command,env_file:$input.env_file,
      endpoint:($profile.backend.endpoint // $manifest.endpoint),
      api_key_env:(if $profile.backend | has("api_key_env") then
        $profile.backend.api_key_env else $manifest.api_key_env end),
      insecure_tls:($profile.backend.insecure_tls // false),
      http_timeout:($profile.backend.http_timeout // 3600),
      http_stall:($profile.backend.http_stall // 300)} +
      (if $input.context_window_command == "" then {}
       else {context_window_command:$input.context_window_command} end),
    harness:({
      sandbox_read_paths:(($profile.harness.sandbox_read_paths // []) + $input.sandbox_read_paths),
      sandbox_write_paths:(($profile.harness.sandbox_write_paths // []) + $input.sandbox_write_paths),
      fence:$input.fence,tools:$tools,
      sandbox:(if $profile.harness | has("sandbox")
        then $profile.harness.sandbox else true end),
      max_requests_per_turn:($profile.harness.max_requests_per_turn // 100),
      max_tool_calls_per_request:($profile.harness.max_tool_calls_per_request // 25),
      max_capture_bytes:($profile.harness.max_capture_bytes // 32768)} + $hooks)
  }) as $runtime |
  {runtime:$runtime};
