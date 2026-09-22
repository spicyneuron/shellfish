# Theme selection, colors, and preview limits, merged from the bundled
# $defaults and the user's $raw config. Self-contained: a client owns no core
# jq module, so the helpers below are copies.

def profile_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$");

def preview_lines:
  . == "full" or (type == "number" and floor == . and . >= 0 and . <= 2147483647);

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

# The keys a config contributes to presentation. The core owns the rest.
def presentation_keys: {theme_mode, theme_light, theme_dark, tui, themes};

# Input is already narrowed to presentation_keys, so only nested shapes need
# an unknown-field check.
def config_presentation:
  config_assert((has("theme_mode") | not) or (.theme_mode | IN("auto", "light", "dark"));
    ["theme_mode"]; "invalid theme mode") |
  config_assert((has("theme_light") | not) or (.theme_light | profile_name);
    ["theme_light"]; "invalid theme") |
  config_assert((has("theme_dark") | not) or (.theme_dark | profile_name);
    ["theme_dark"]; "invalid theme") |
  if has("themes") then .themes |= (to_entries | map(.key as $name |
    config_assert($name | profile_name; ["themes", $name]; "invalid name") |
    .value |= config_theme(["themes", $name])) | from_entries) else . end |
  if has("tui") then .tui |= (
    ["preview_lines_reasoning", "preview_lines"] as $preview_fields |
    config_object(["tui"]; $preview_fields) |
    reduce $preview_fields[] as $field (.;
      config_assert((has($field) | not) or (.[$field] | preview_lines);
        ["tui", $field]; "must be full or a non-negative integer"))) else . end;

# Whichever theme the current mode selects must exist.
def presentation_finish:
  . as $config |
  ([$config.theme_light, $config.theme_dark] | unique | map(. as $name |
    select($config.themes | has($name) | not)) | join(", ")) as $missing |
  if $missing != "" then error("shellfish:unknown-theme:" + $missing)
  else $config end;

if $raw | type != "object" then error("shellfish:invalid-config")
else
  ($defaults | presentation_keys) *
  ($raw | presentation_keys | with_entries(select(.value != null))) |
  config_presentation | presentation_finish
end
