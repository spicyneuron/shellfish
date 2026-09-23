#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

profile_eval() {
  jq -L "$ROOT" -e 'include "lib/runtime"; '"$1"
}

# Profile validation rejects invalid fields.
for profile in \
    '{"legacy_backend":"test"}' \
    '{"context_window":0}' \
    '{"themes":{"dark":{"text":"red"}}}' \
    '{"extend":"default"}' \
    '{"harness":{}}' \
    '{"hooks":{"unexpected":[]}}' \
    '{"tools":"read_file"}' \
    '{"backend":{"endpoint":"ftp://example.invalid"}}'; do
  if print -r -- "$profile" | profile_eval 'config_profile(["p"])' >/dev/null 2>&1; then
    fail "invalid profile was accepted: $profile"
  fi
done
print -r -- '{"context_window":null}' | profile_eval 'config_profile(["p"])' >/dev/null

# Objects merge recursively, arrays replace, and "..." splices.
jq -n -L "$ROOT" -e '
  include "lib/runtime";
  ({request:{reasoning:{effort:"high"}},tools:["...","mine"],system:["only.md"]} |
    merge_over({request:{model:"base",reasoning:{effort:"low",budget:1}},
      tools:["a","b"],sandbox:false,system:["base.md"]})) == {
    request:{model:"base",reasoning:{effort:"high",budget:1}},
    tools:["a","b","mine"],sandbox:false,
    system:["only.md"]
  }' >/dev/null

# Diamonds resolve once; cycles error.
jq -n -L "$ROOT" -e '
  include "lib/runtime";
  profile_resolve({
    base:{request:{model:"base"}},
    left:{extend:["base"],sandbox:false},
    right:{extend:["base"],system:["r.md"]},
    leaf:{extend:["left","right"]}
  }; ["leaf"]) == {
    request:{model:"base"},sandbox:false,system:["r.md"]
  }' >/dev/null
if jq -n -L "$ROOT" -e '
    include "lib/runtime";
    profile_resolve({a:{extend:["b"]},b:{extend:["a"]}}; ["a"])
  ' >/dev/null 2>&1; then
  fail 'profile inheritance cycle was accepted'
fi

# A shared parent applies once, so a splice it reaches twice does not repeat.
jq -n -L "$ROOT" -e '
  include "lib/runtime";
  profile_resolve({
    base:{system:["base.md"]},
    add:{extend:["base"],system:["...","add.md"]},
    leaf:{extend:["add","base"]}
  }; ["leaf","add"]) == {system:["base.md","add.md"]}' >/dev/null

# Later --profile names override earlier ones.
jq -n -L "$ROOT" -e '
  include "lib/runtime";
  profile_resolve({one:{request:{model:"one"},system:["one.md"]},
    two:{request:{model:"two"}}}; ["one","two"]) ==
    {request:{model:"two"},system:["one.md"]}' >/dev/null

# Selection applies CLI overrides and requires a model and an adapter.
jq -n -L "$ROOT" -e '
  include "lib/runtime";
  profile_select({p:{backend:{adapter:"openai"},request:{model:"base"}}}; ["p"];
    "cli"; {seed:1}; "other"; "") ==
    {backend:{adapter:"other"},request:{model:"cli",seed:1}}' >/dev/null
# "p" has no model; "q" has no adapter.
for name in p q; do
  if jq -n -L "$ROOT" --arg name "$name" -e '
      include "lib/runtime";
      profile_select({p:{backend:{adapter:"openai"}},q:{request:{model:"m"}}};
        [$name]; ""; {}; ""; "")' >/dev/null 2>&1; then
    fail "incomplete profile was accepted: $name"
  fi
done

# Component lookup through profile folders.
sf_test_source lib/runtime.zsh
sf_test_tmp resolve
sf_test_config
export HOME="$tmp/home"
typeset profiles="${SF_TEST_CONFIG:A}/profiles"
mkdir -p "$HOME/prompts" "$profiles"/{far,near,later,default}/system "$profiles/far/tools/probe"
print -r -- '#!/bin/sh' >"$profiles/far/tools/probe/run"
chmod +x "$profiles/far/tools/probe/run"
print -r -- '{"description":"probe","input_schema":{"type":"object"},"sandbox":false}' \
  >"$profiles/far/tools/probe/manifest.json"
for folder in far near later default; do
  print -r -- "$folder" >"$profiles/$folder/system/shared.md"
done
print -r -- 'home' >"$HOME/prompts/home.md"
sf_test_profile far '{"backend": {"adapter": "'"$SF_TEST_BACKEND:h"'"},
  "request": {"model": "m"}, "tools": ["probe"], "system": ["shared.md"]}'
sf_test_profile near '{"extend": ["far"]}'
sf_test_profile later '{}'

# The most-derived folder wins, and parents still supply what it lacks.
sf_runtime_resolve_args -p near
jq -e --arg base "$profiles" '
  .system == [$base + "/near/system/shared.md"] and
  .harness.tools[0].command == $base + "/far/tools/probe/run"' <<<"$REPLY" >/dev/null

# A later -p is more derived than an earlier one.
sf_runtime_resolve_args -p near -p later
jq -e --arg base "$profiles" '.system == [$base + "/later/system/shared.md"]' <<<"$REPLY" >/dev/null

# "@NAME/path" is the bundled folder even when a user folder shadows the name;
# "~/" and absolute paths are taken as written.
sf_test_profile default '{"extend": ["far"], "system": ["shared.md",
  "@default/system/general.md", "~/prompts/home.md", "'"$HOME"'/prompts/home.md"]}'
sf_runtime_resolve_args
jq -e --arg base "$profiles" --arg home "${HOME:A}" --arg bundled "$ROOT/share/profiles/default" '
  .system == [$base + "/default/system/shared.md", $bundled + "/system/general.md",
    $home + "/prompts/home.md", $home + "/prompts/home.md"]' <<<"$REPLY" >/dev/null

# Bare names never fall back to the bundled folder.
sf_test_profile default '{"extend": ["far"], "system": ["general.md"]}'
if sf_runtime_resolve_args; then
  fail 'bare name resolved outside the profile folders'
fi
[[ $SF_RUNTIME_ERROR == 'cannot resolve system reference: general.md' ]]
