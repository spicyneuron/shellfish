# Theme selection, colors, and preview limits, merged from the bundled
# $defaults and the user's $raw config. Self-contained: a client owns no core
# jq module.
#
# Only value shapes are checked. Defaults supply every color and limit, so an
# unrecognized key is merely unused, and listing the known ones here would be
# one more copy to keep in step with the renderer.

def config_error($path; $message):
  error("invalid config at $" + ($path | map("[" + tojson + "]") | join("")) + ": " + $message);
def config_assert($valid; $path; $message):
  if $valid then . else config_error($path; $message) end;

# The keys a config contributes to presentation. The core owns the rest.
def presentation_keys: {theme_mode, theme_light, theme_dark, tui, themes};

def config_presentation:
  config_assert((has("theme_mode") | not) or (.theme_mode | IN("auto", "light", "dark"));
    ["theme_mode"]; "invalid theme mode") |
  reduce ["theme_light", "theme_dark"][] as $field (.;
    config_assert((has($field) | not) or (.[$field] | type == "string");
      [$field]; "must name a theme")) |
  config_assert((has("themes") | not) or (.themes | type == "object");
    ["themes"]; "must be an object") |
  reduce (.themes // {} | to_entries[]) as $theme (.;
    config_assert($theme.value | type == "object";
      ["themes", $theme.key]; "must be an object") |
    reduce ($theme.value | to_entries[]) as $color (.;
      config_assert($color.value | type == "string" and
        test("^#[0-9A-Fa-f]{6}$");
        ["themes", $theme.key, $color.key]; "must be a #RRGGBB color"))) |
  config_assert((has("tui") | not) or (.tui | type == "object");
    ["tui"]; "must be an object") |
  reduce ["preview_lines_reasoning", "preview_lines"][] as $field (.;
    config_assert((.tui // {} | has($field) | not) or
      (.tui[$field] | . == "full" or (type == "number" and floor == . and . >= 0));
      ["tui", $field]; "must be full or a non-negative integer"));

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
