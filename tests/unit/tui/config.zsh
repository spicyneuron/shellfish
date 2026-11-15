#!/usr/bin/env zsh

# Presentation resolves from its own config. A session never freezes it, and
# a profile never carries it.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/config.zsh
sf_test_tmp presentation

mkdir -p "$tmp/shellfish" "$tmp/home"
export HOME="${tmp:A}/home"
export SHELLFISH_DIR="${tmp:A}/shellfish"
typeset config="$tmp/shellfish/tui.jsonc"

cat >"$config" <<'JSON'
{
  "theme_mode": "light",
  "theme_light": "light",
  "theme_dark": "dark",
  "themes": {
    "light": {"text": "#123456"}
  },
  "preview_lines": 9
}
JSON

# A configured palette merges over the bundled one.
sf_tui_config_resolve
jq -e '
  .theme_mode == "light" and .theme_light == "light" and
  .themes.light.text == "#123456" and .themes.light.muted == "#828e9f" and
  .preview_lines == 9 and .preview_lines_reasoning == 0
' <<<"$SF_TUI_CONFIG" >/dev/null

# --verbose widens both limits.
SF_TUI_CONFIG_VERBOSE=1
sf_tui_config_resolve
jq -e '.preview_lines == "full" and .preview_lines_reasoning == "full"' \
  <<<"$SF_TUI_CONFIG" >/dev/null
SF_TUI_CONFIG_VERBOSE=0

# Without a config, the bundled defaults stand alone.
rm "$config"
sf_tui_config_resolve
jq -e '.theme_mode == "auto" and .preview_lines == 2' <<<"$SF_TUI_CONFIG" >/dev/null

# A selected theme must exist.
print -r -- '{"theme_light":"missing"}' >"$config"
if sf_tui_config_resolve; then
  fail 'missing current theme was accepted'
fi
[[ $SF_TUI_CONFIG_ERROR == 'unknown theme: missing' ]]

# Presentation fields report their own path.
print -r -- '{"preview_lines":-1}' >"$config"
if sf_tui_config_resolve; then
  fail 'invalid presentation field was accepted'
fi
[[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["preview_lines"]: must be full or a non-negative integer'* ]]

# Verbose does not hide invalid settings.
SF_TUI_CONFIG_VERBOSE=1
if sf_tui_config_resolve; then fail 'verbose hid an invalid preview limit'; fi
[[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["preview_lines"]'* ]]
SF_TUI_CONFIG_VERBOSE=0

for limit in 0 2147483647; do
  print -r -- "{\"preview_lines\":$limit}" >"$config"
  sf_tui_config_resolve
  assert_equal "$limit" "$(jq -r .preview_lines <<<"$SF_TUI_CONFIG")"
done
for limit in 1.5 2147483648; do
  print -r -- "{\"preview_lines\":$limit}" >"$config"
  if sf_tui_config_resolve; then fail "invalid preview limit $limit was accepted"; fi
  [[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["preview_lines"]'* ]]
done

print -r -- '{"themes":{"light":{"text":"blue"}}}' >"$config"
if sf_tui_config_resolve; then
  fail 'invalid theme color was accepted'
fi
[[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["themes"]["light"]["text"]: must be a #RRGGBB color'* ]]

# The executable validator matches the schema rather than ignoring typos.
print -r -- '{"preview_line":2}' >"$config"
if sf_tui_config_resolve; then
  fail 'unknown TUI field was accepted'
fi
[[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["preview_line"]: unknown field'* ]]

print -r -- '{"themes":{"dark":{"agnt":"#ffffff"}}}' >"$config"
if sf_tui_config_resolve; then
  fail 'unknown theme color was accepted'
fi
[[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["themes"]["dark"]["agnt"]: unknown field'* ]]

print -r -- '{"preview_lines":null}' >"$config"
if sf_tui_config_resolve; then
  fail 'null TUI field was accepted'
fi
[[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["preview_lines"]: must be full or a non-negative integer'* ]]

# A syntax error keeps the line jq reported.
print -r -- '{"preview_lines": 2' >"$config"
if sf_tui_config_resolve; then
  fail 'malformed TUI config was accepted'
fi
[[ $SF_TUI_CONFIG_ERROR == *'invalid TUI config: '*'tui.jsonc: parse error'* ]]

# Runtime field names and limits come from the installed schema.
(
  mkdir "$tmp/share"
  cp "$SF_SHARE/tui.jsonc" "$tmp/share/"
  jq '."$defs".theme.properties.accent={"$ref":"#/$defs/color"} |
    ."$defs".preview_lines.oneOf[0].maximum=3' \
    "$SF_SHARE/tui.schema.json" >"$tmp/share/tui.schema.json"
  SF_SHARE=$tmp/share
  print -r -- '{"themes":{"light":{"accent":"#123456"}},"preview_lines":3}' >"$config"
  sf_tui_config_resolve
  jq -e '.themes.light.accent == "#123456" and .preview_lines == 3' \
    <<<"$SF_TUI_CONFIG" >/dev/null
  print -r -- '{"preview_lines":4}' >"$config"
  if sf_tui_config_resolve; then fail 'runtime ignored the schema preview bound'; fi
  [[ $SF_TUI_CONFIG_ERROR == *'invalid config at $["preview_lines"]'* ]]
)
