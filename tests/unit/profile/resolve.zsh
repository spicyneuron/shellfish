#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

profile_eval() {
  jq -L "$ROOT" -e 'include "lib/profile"; '"$1"
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
  include "lib/profile";
  ({request:{reasoning:{effort:"high"}},tools:["...","mine"],system:["only.md"]} |
    merge_over({request:{model:"base",reasoning:{effort:"low",budget:1}},
      tools:["a","b"],sandbox:false,system:["base.md"]})) == {
    request:{model:"base",reasoning:{effort:"high",budget:1}},
    tools:["a","b","mine"],sandbox:false,
    system:["only.md"]
  }' >/dev/null

# Diamonds resolve once; cycles error.
jq -n -L "$ROOT" -e '
  include "lib/profile";
  profile_resolve({
    base:{request:{model:"base"}},
    left:{extend:["base"],sandbox:false},
    right:{extend:["base"],system:["r.md"]},
    leaf:{extend:["left","right"]}
  }; ["leaf"]) == {
    request:{model:"base"},sandbox:false,system:["r.md"]
  }' >/dev/null
if jq -n -L "$ROOT" -e '
    include "lib/profile";
    profile_resolve({a:{extend:["b"]},b:{extend:["a"]}}; ["a"])
  ' >/dev/null 2>&1; then
  fail 'profile inheritance cycle was accepted'
fi

# A shared parent applies once, so a splice it reaches twice does not repeat.
jq -n -L "$ROOT" -e '
  include "lib/profile";
  profile_resolve({
    base:{system:["base.md"]},
    add:{extend:["base"],system:["...","add.md"]},
    leaf:{extend:["add","base"]}
  }; ["leaf","add"]) == {system:["base.md","add.md"]}' >/dev/null

# Later --profile names override earlier ones.
jq -n -L "$ROOT" -e '
  include "lib/profile";
  profile_resolve({one:{request:{model:"one"},system:["one.md"]},
    two:{request:{model:"two"}}}; ["one","two"]) ==
    {request:{model:"two"},system:["one.md"]}' >/dev/null

# Selection applies CLI overrides, requires a model and an adapter, and fills
# defaults.
jq -n -L "$ROOT" -e '
  include "lib/profile";
  profile_select({p:{backend:{adapter:"openai"},request:{model:"base"},sandbox:false}};
    ["p"]; "cli"; {seed:1}; "other") == {
    backend:{adapter:"other",insecure_tls:false,http_timeout:3600,http_stall:300},
    request:{model:"cli",seed:1}, system:[], tools:[], hooks:{}, sandbox:false,
    sandbox_read_paths:[], sandbox_write_paths:[], max_requests_per_turn:100,
    max_tool_calls_per_request:25, max_capture_bytes:32768}' >/dev/null
# "p" has no model; "q" has no adapter.
for name in p q; do
  if jq -n -L "$ROOT" --arg name "$name" -e '
      include "lib/profile";
      profile_select({p:{backend:{adapter:"openai"}},q:{request:{model:"m"}}};
        [$name]; ""; {}; "")' >/dev/null 2>&1; then
    fail "incomplete profile was accepted: $name"
  fi
done

# Component lookup through profile folders.
sf_test_source lib/profile.zsh
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
sf_profile_resolve_args -p near
jq -e --arg base "$profiles" '
  .system == [$base + "/near/system/shared.md"] and
  .tools == [$base + "/far/tools/probe"]' <<<"$REPLY" >/dev/null

# A later -p is more derived than an earlier one.
sf_profile_resolve_args -p near -p later
jq -e --arg base "$profiles" '.system == [$base + "/later/system/shared.md"]' <<<"$REPLY" >/dev/null

# "@KIND/path" selects the bundled component despite user shadowing;
# "~/" and absolute paths are taken as written.
sf_test_profile default '{"extend": ["far"], "system": ["shared.md",
  "@system/general.md", "~/prompts/home.md", "'"$HOME"'/prompts/home.md"]}'
sf_profile_resolve_args
jq -e --arg base "$profiles" --arg home "${HOME:A}" --arg bundled "$ROOT/share" '
  .system == [$base + "/default/system/shared.md", $bundled + "/system/general.md",
    $home + "/prompts/home.md", $home + "/prompts/home.md"]' <<<"$REPLY" >/dev/null

# Bare names fall back to the bundled kind directory.
sf_test_profile default '{"extend": ["far"], "system": ["general.md"]}'
sf_profile_resolve_args
jq -e --arg bundled "$ROOT/share" '.system == [$bundled + "/system/general.md"]' \
  <<<"$REPLY" >/dev/null

# Flat profiles select components from fixed kind directories, independent of
# which profile supplied the reference.
(
  SF_SHARE="$tmp/flat-share"
  mkdir -p "$SF_SHARE/profiles/deep" "$SF_SHARE/system" "$SF_SHARE/hooks" \
    "$SF_SHARE/backends/demo" "$SF_TEST_CONFIG/system" \
    "$SF_TEST_CONFIG/profiles/deep" "$SF_TEST_CONFIG/tools/probe"
  print -r -- 'bundled' >"$SF_SHARE/system/general.md"
  print -r -- 'configured' >"$SF_TEST_CONFIG/system/general.md"
  print -r -- '#!/bin/sh' >"$SF_SHARE/hooks/stop"
  print -r -- '#!/bin/sh' >"$SF_SHARE/backends/demo/run"
  print -r -- '#!/bin/sh' >"$SF_TEST_CONFIG/tools/probe/run"
  chmod +x "$SF_SHARE/hooks/stop" "$SF_SHARE/backends/demo/run" \
    "$SF_TEST_CONFIG/tools/probe/run"
  print -r -- '{"endpoint":"https://example.invalid/test"}' \
    >"$SF_SHARE/backends/demo/manifest.jsonc"
  print -r -- '{"description":"probe","input_schema":{"type":"object"},"sandbox":false}' \
    >"$SF_TEST_CONFIG/tools/probe/manifest.jsonc"
  mkdir -p "$SF_TEST_CONFIG/tools/unused"
  print -r -- 'not a manifest' >"$SF_TEST_CONFIG/tools/unused/manifest.jsonc"
  print -r -- '{"backend":{"adapter":"@backends/demo"},"request":{"model":"bundled"}}' \
    >"$SF_SHARE/profiles/default.jsonc"
  print -r -- '{"backend":{"adapter":"@backends/demo"},"request":{"model":"mine"},
    "system":["general.md","@system/general.md"],"tools":["probe"],
    "hooks":{"stop":["@hooks/stop"]}}' >"$SF_TEST_CONFIG/profiles/default.jsonc"
  print -r -- '{"extend":["default"],"request":{"model":"variant"}}' \
    >"$SF_TEST_CONFIG/profiles/deep/variant.jsonc"
  print -r -- '{"extend":["@default"],"request":{"model":"bundled-variant"}}' \
    >"$SF_SHARE/profiles/deep/variant.jsonc"
  sf_profile_resolve_args -p deep/variant
  jq -e --arg configured "${SF_TEST_CONFIG:A}" --arg bundled "${SF_SHARE:A}" '
    .request.model == "variant" and
    .system == [$configured + "/system/general.md", $bundled + "/system/general.md"] and
    .tools == [$configured + "/tools/probe"] and
    .hooks.stop == [$bundled + "/hooks/stop"] and
    .backend.adapter == ($bundled + "/backends/demo")
  ' <<<"$REPLY" >/dev/null
  sf_profile_resolve_args -p @deep/variant
  jq -e '.request.model == "bundled-variant" and .system == []' <<<"$REPLY" >/dev/null
  sf_profile_resolve_args -p deep/variant -m overridden
  jq -e '.request.model == "overridden"' <<<"$REPLY" >/dev/null
  print -r -- '{"extend":["default"],"tools":["missing"]}' \
    >"$SF_TEST_CONFIG/profiles/bad.jsonc"
  if sf_profile_resolve_args -p bad; then
    fail 'missing flat component was accepted'
  fi
  [[ $SF_PROFILE_ERROR == 'cannot resolve tools reference: missing' ]]
  print -r -- '{"extend":["default"],"hooks":{"stop":["general.md"]}}' \
    >"$SF_TEST_CONFIG/profiles/bad.jsonc"
  if sf_profile_resolve_args -p bad; then
    fail 'invalid flat hook was accepted'
  fi
  [[ $SF_PROFILE_ERROR == 'cannot resolve hooks reference: general.md' ]]
  print -r -- 'not executable' >"$SF_SHARE/hooks/disabled"
  print -r -- '{"extend":["default"],"hooks":{"stop":["@hooks/disabled"]}}' \
    >"$SF_TEST_CONFIG/profiles/bad.jsonc"
  if sf_profile_resolve_args -p bad; then
    fail 'non-executable flat hook was accepted'
  fi
  [[ $SF_PROFILE_ERROR == 'invalid hooks reference: @hooks/disabled' ]]
)
