#!/usr/bin/env zsh

# Presentation resolves from config alone. A session never freezes it, so
# resolving a runtime neither produces nor validates these settings.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/presentation.zsh
sf_test_tmp presentation

mkdir -p "$tmp/config" "$tmp/home"
export HOME="${tmp:A}/home"
unset XDG_CONFIG_HOME
typeset config="$tmp/config/shellfish.jsonc"

cat >"$config" <<'JSON'
{
  "default_profile": "work",
  "theme_mode": "light",
  "theme_light": "light",
  "theme_dark": "dark",
  "profiles": {
    "work": {"request": {"model": "configured"}}
  },
  "themes": {
    "light": {"text": "#123456"}
  }
}
JSON

# Configured themes merge over the bundled defaults.
sf_presentation_resolve "$config"
jq -e '
  .theme_mode == "light" and .theme_light == "light" and
  .themes.light.text == "#123456" and
  .tui.preview_lines == 2
' <<<"$SF_PRESENTATION" >/dev/null

# Reopening reads presentation without touching profiles.
cat >"$tmp/config/presentation.jsonc" <<'JSON'
{
  "profiles": "ignored while reopening",
  "theme_mode": "light",
  "theme_light": "light",
  "theme_dark": "dark",
  "themes": {"light": {"text": "#abcdef"}},
  "tui": {"preview_lines": 9}
}
JSON
sf_presentation_resolve "$tmp/config/presentation.jsonc"
jq -e '
  .theme_mode == "light" and .themes.light.text == "#abcdef" and
  .tui.preview_lines == 9
' <<<"$SF_PRESENTATION" >/dev/null

# A selected theme must exist.
print -r -- '{"theme_light":"missing"}' >"$tmp/config/missing-theme.jsonc"
if sf_presentation_resolve "$tmp/config/missing-theme.jsonc"; then
  fail 'missing current theme was accepted'
fi
[[ $SF_PRESENTATION_ERROR == 'unknown theme: missing' ]]

# Presentation fields report their own path.
print -r -- '{"tui":{"preview_lines":-1}}' >"$tmp/config/invalid-preview.jsonc"
if sf_presentation_resolve "$tmp/config/invalid-preview.jsonc"; then
  fail 'invalid presentation field was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid config at $["tui"]["preview_lines"]: must be full or a non-negative integer'* ]]

print -r -- '{"themes":{"light":{"text":"blue"}}}' >"$tmp/config/invalid-color.jsonc"
if sf_presentation_resolve "$tmp/config/invalid-color.jsonc"; then
  fail 'invalid theme color was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid config at $["themes"]["light"]["text"]: must be a #RRGGBB color'* ]]
