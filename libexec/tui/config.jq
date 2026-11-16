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
  type == "string" and test($schema[0]."$defs".name.pattern);

def config_presentation:
  $schema[0]."$defs".preview_lines.oneOf as [$range, $full] |
  config_object([]; ($schema[0].properties | keys)) |
  config_assert((has("$schema") | not) or (."$schema" | type == "string");
    ["$schema"]; "must be a string") |
  config_assert((has("theme_mode") | not) or
    (.theme_mode | IN($schema[0].properties.theme_mode.enum[]));
    ["theme_mode"]; "invalid theme mode") |
  reduce ["theme_light", "theme_dark"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | config_name);
      [$field]; "must name a theme")) |
  config_assert((has("themes") | not) or (.themes | type == "object");
    ["themes"]; "must be an object") |
  reduce (.themes // {} | to_entries[]) as $theme (.;
    config_assert($theme.key | config_name; ["themes", $theme.key]; "invalid name") |
    ($theme.value | config_object(["themes", $theme.key];
      ($schema[0]."$defs".theme.properties | keys))) as $_ |
    reduce ($theme.value | to_entries[]) as $color (.;
      config_assert($color.value | type == "string" and
        test($schema[0]."$defs".color.pattern);
        ["themes", $theme.key, $color.key]; "must be a #RRGGBB color"))) |
  reduce ["preview_lines_reasoning", "preview_lines"][] as $field (.;
    config_assert((has($field) | not) or
      (.[$field] | . == $full.const or
        (type == "number" and floor == . and . >= $range.minimum and . <= $range.maximum));
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
  config_presentation | presentation_finish |
  if $verbose != 0 then .preview_lines_reasoning = "full" | .preview_lines = "full"
  else . end
end
