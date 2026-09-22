#!/usr/bin/env zsh

# Presentation resolves from its own config. A session never freezes it, and
# the runtime config never carries it.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/presentation.zsh
sf_test_tmp presentation

mkdir -p "$tmp/config/shellfish" "$tmp/home"
export HOME="${tmp:A}/home"
export XDG_CONFIG_HOME="${tmp:A}/config"
typeset config="$tmp/config/shellfish/tui.jsonc"

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
sf_presentation_resolve
jq -e '
  .theme_mode == "light" and .theme_light == "light" and
  .themes.light.text == "#123456" and .themes.light.muted == "#828e9f" and
  .preview_lines == 9 and .preview_lines_reasoning == 0
' <<<"$SF_PRESENTATION" >/dev/null

# --verbose widens both limits.
SF_PRESENTATION_VERBOSE=1
sf_presentation_resolve
jq -e '.preview_lines == "full" and .preview_lines_reasoning == "full"' \
  <<<"$SF_PRESENTATION" >/dev/null
SF_PRESENTATION_VERBOSE=0

# Without a config, the bundled defaults stand alone.
rm "$config"
sf_presentation_resolve
jq -e '.theme_mode == "auto" and .preview_lines == 2' <<<"$SF_PRESENTATION" >/dev/null

# A selected theme must exist.
print -r -- '{"theme_light":"missing"}' >"$config"
if sf_presentation_resolve; then
  fail 'missing current theme was accepted'
fi
[[ $SF_PRESENTATION_ERROR == 'unknown theme: missing' ]]

# Presentation fields report their own path.
print -r -- '{"preview_lines":-1}' >"$config"
if sf_presentation_resolve; then
  fail 'invalid presentation field was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid config at $["preview_lines"]: must be full or a non-negative integer'* ]]

print -r -- '{"themes":{"light":{"text":"blue"}}}' >"$config"
if sf_presentation_resolve; then
  fail 'invalid theme color was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid config at $["themes"]["light"]["text"]: must be a #RRGGBB color'* ]]

# The executable validator matches the schema rather than ignoring typos.
print -r -- '{"preview_line":2}' >"$config"
if sf_presentation_resolve; then
  fail 'unknown TUI field was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid config at $["preview_line"]: unknown field'* ]]

print -r -- '{"themes":{"dark":{"agnt":"#ffffff"}}}' >"$config"
if sf_presentation_resolve; then
  fail 'unknown theme color was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid config at $["themes"]["dark"]["agnt"]: unknown field'* ]]

print -r -- '{"preview_lines":null}' >"$config"
if sf_presentation_resolve; then
  fail 'null TUI field was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid config at $["preview_lines"]: must be full or a non-negative integer'* ]]

# A syntax error keeps the line jq reported.
print -r -- '{"preview_lines": 2' >"$config"
if sf_presentation_resolve; then
  fail 'malformed TUI config was accepted'
fi
[[ $SF_PRESENTATION_ERROR == *'invalid TUI config: '*'tui.jsonc: parse error'* ]]
