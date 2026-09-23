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
    '{"harness":{"unexpected":[]}}' \
    '{"backend":{"endpoint":"ftp://example.invalid"}}'; do
  if print -r -- "$profile" | profile_eval 'config_profile(["p"])' >/dev/null 2>&1; then
    fail "invalid profile was accepted: $profile"
  fi
done
print -r -- '{"context_window":null}' | profile_eval 'config_profile(["p"])' >/dev/null

# Objects merge recursively, arrays replace, and "..." splices.
jq -n -L "$ROOT" -e '
  include "lib/runtime";
  ({request:{reasoning:{effort:"high"}},harness:{tools:["...","mine"]},system:["only.md"]} |
    merge_over({request:{model:"base",reasoning:{effort:"low",budget:1}},
      harness:{tools:["a","b"],sandbox:false},system:["base.md"]})) == {
    request:{model:"base",reasoning:{effort:"high",budget:1}},
    harness:{tools:["a","b","mine"],sandbox:false},
    system:["only.md"]
  }' >/dev/null

# Diamonds resolve once; cycles error.
jq -n -L "$ROOT" -e '
  include "lib/runtime";
  profile_resolve({
    base:{request:{model:"base"}},
    left:{extend:["base"],harness:{sandbox:false}},
    right:{extend:["base"],system:["r.md"]},
    leaf:{extend:["left","right"]}
  }; ["leaf"]) == {
    request:{model:"base"},harness:{sandbox:false},system:["r.md"]
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
    {backend:{adapter:"other"},request:{model:"cli",seed:1},harness:{}}' >/dev/null
# "p" has no model; "q" has no adapter.
for name in p q; do
  if jq -n -L "$ROOT" --arg name "$name" -e '
      include "lib/runtime";
      profile_select({p:{backend:{adapter:"openai"}},q:{request:{model:"m"}}};
        [$name]; ""; {}; ""; "")' >/dev/null 2>&1; then
    fail "incomplete profile was accepted: $name"
  fi
done
