#!/usr/bin/env zsh

# Every forwarded profile option is one the profile parser accepts.

source "${0:A:h:h}/_helpers.zsh"
sf_test_source lib/options.zsh
sf_test_source lib/profile.zsh

typeset name
for name in $SF_CREATE_OPTIONS; do
  [[ $name != --session-from ]] || continue
  sf_profile_resolve_args "$name" "" 2>/dev/null || true
  [[ $SF_ERROR != 'unknown argument:'* ]] ||
    fail "lib/options.zsh forwards $name but lib/profile.zsh does not parse it"
done
