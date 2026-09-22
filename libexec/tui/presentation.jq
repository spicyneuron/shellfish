# Theme selection, colors, and preview limits, merged from the bundled
# $defaults and the user's $raw config. Self-contained: a client owns no core
# jq module.

def config_error($path; $message):
  error("invalid config at $" + ($path | map("[" + tojson + "]") | join("")) + ": " + $message);
def config_assert($valid; $path; $message):
  if $valid then . else config_error($path; $message) end;
def config_object($path; $fields):
  config_assert(type == "object"; $path; "must be an object") |
  config_assert((keys - $fields | length) == 0; $path + [(keys - $fields)[0]]; "unknown field");
def config_name:
  type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$");

def config_presentation:
  config_object([]; ["$schema", "theme_mode", "theme_light", "theme_dark", "themes",
    "preview_lines_reasoning", "preview_lines"]) |
  config_assert((has("$schema") | not) or (."$schema" | type == "string");
    ["$schema"]; "must be a string") |
  config_assert((has("theme_mode") | not) or (.theme_mode | IN("auto", "light", "dark"));
    ["theme_mode"]; "invalid theme mode") |
  reduce ["theme_light", "theme_dark"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | config_name);
      [$field]; "must name a theme")) |
  config_assert((has("themes") | not) or (.themes | type == "object");
    ["themes"]; "must be an object") |
  reduce (.themes // {} | to_entries[]) as $theme (.;
    config_assert($theme.key | config_name; ["themes", $theme.key]; "invalid name") |
    ($theme.value | config_object(["themes", $theme.key];
      ["text", "muted", "divider", "footer", "prompt", "prompt_waiting", "system",
       "context", "user", "agent", "activity", "link", "code", "tool", "reasoning",
       "error", "syntax_comment", "syntax_keyword", "syntax_string", "syntax_number",
       "syntax_tag", "diff_added", "diff_added_background", "diff_removed",
       "diff_removed_background", "permission"])) as $_ |
    reduce ($theme.value | to_entries[]) as $color (.;
      config_assert($color.value | type == "string" and
        test("^#[0-9A-Fa-f]{6}$");
        ["themes", $theme.key, $color.key]; "must be a #RRGGBB color"))) |
  reduce ["preview_lines_reasoning", "preview_lines"][] as $field (.;
    config_assert((has($field) | not) or
      (.[$field] | . == "full" or
        (type == "number" and floor == . and . >= 0 and . <= 2147483647));
      [$field]; "must be full or a non-negative integer"));

# Whichever theme the current mode selects must exist.
def presentation_finish:
  . as $config |
  ([$config.theme_light, $config.theme_dark] | unique | map(. as $name |
    select($config.themes | has($name) | not)) | join(", ")) as $missing |
  if $missing != "" then error("shellfish:unknown-theme:" + $missing)
  else $config end;

if $raw | type != "object" then error("shellfish:invalid-config")
else
  $defaults * $raw |
  config_presentation | presentation_finish
end
