#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

config_eval() {
  jq -L "$ROOT" -e 'include "libexec/config/runtime"; '"$1"
}

# Profile inheritance rejects cycles.
if print -r -- '{"bundled":{},"configured":{"a":{"extend":"b"},"b":{"extend":"a"}},"backends":{},"harnesses":{},"themes":{}}' |
    jq -L "$ROOT" -e '
      include "libexec/config/runtime";
      config_resolve_profiles(.bundled; .configured; .backends; .harnesses)
    ' >/dev/null 2>&1; then
  fail 'profile inheritance cycle was accepted'
fi

# Profile validation rejects invalid fields.
if print -r -- '{"profiles":{"work":{"legacy_backend":"test"}}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'unknown profile field was accepted'
fi
if print -r -- '{"profiles":{"work":{"context_window":0}}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'invalid profile context window was accepted'
fi
print -r -- '{"profiles":{"work":{"context_window":null}}}' |
  config_eval 'config_validate' >/dev/null

# Theme colors require hex values.
if print -r -- '{"themes":{"dark":{"text":"red"}}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'invalid theme color was accepted'
fi
if print -r -- '{"themes":{"dark":{"syntax_keyword":"red"}}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'invalid syntax color was accepted'
fi

# Preview line counts require valid types.
if print -r -- '{"tui":{"preview_lines_context":-1}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'invalid tui preview_lines was accepted'
fi
if print -r -- '{"tui":{"preview_lines_tool_call":true}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'invalid tool call preview_lines was accepted'
fi

# TUI headings are fixed.
if print -r -- '{"tui":{"agent_heading":"custom"}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'custom TUI heading was accepted'
fi

# Harnesses reject unknown hooks.
if print -r -- '{"harnesses":{"bad":{"session_end":[]}}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'removed session_end hook was accepted'
fi

# Profile extensions inherit and override.
typeset resolved_profile
resolved_profile=$(jq -n -L "$ROOT" '
  include "libexec/config/runtime";
  config_resolve_profiles(
    {default:{backend:"openai",harness:"default",context_window:100000,request:{model:"base"}}};
    {work:{extend:"default",request:{model:"work-model"}}};
    {openai:{adapter:"openai"}};
    {default:{tools:[]}}
  )
')
jq -e '
  .work.backend.name == "openai" and
  .work.harness.name == "default" and
  .work.context_window == 100000 and
  .work.request.model == "work-model"
' <<<"$resolved_profile" >/dev/null
