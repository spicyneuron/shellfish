#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

config_eval() {
  jq -L "$ROOT" -e 'include "lib/runtime"; '"$1"
}

# Profile inheritance rejects cycles.
if print -r -- '{"bundled":{},"configured":{"a":{"extend":"b"},"b":{"extend":"a"}},"backends":{},"harnesses":{},"themes":{}}' |
    jq -L "$ROOT" -e '
      include "lib/runtime";
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

# Presentation belongs to tui.jsonc and has no place here.
if print -r -- '{"themes":{"dark":{"text":"red"}}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'presentation key was accepted'
fi

# Harnesses reject unknown fields.
if print -r -- '{"harnesses":{"bad":{"unexpected":[]}}}' |
    config_eval 'config_validate' >/dev/null 2>&1; then
  fail 'unknown harness field was accepted'
fi

# Profile extensions inherit and override.
typeset resolved_profile
resolved_profile=$(jq -n -L "$ROOT" '
  include "lib/runtime";
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
