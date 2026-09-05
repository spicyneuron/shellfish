#!/usr/bin/env zsh

# lib/options.zsh declares the arity of the options shellfish config owns so
# that forwarding components never guess. It is only correct while it matches
# the parser it describes, so this check derives both the option names and
# their arity from libexec/config/main.zsh.

source "${0:A:h:h}/_helpers.zsh"
sf_test_source lib/options.zsh

# Arms a forwarding component must not pass through: the end-of-options
# separator, and the options it owns itself.
typeset -a not_forwarded=( -- --init --verbose --session )

# Each case arm names its options, and its shift consumes the option plus its
# values, so "shift 2" is arity 1 and a bare "shift" is arity 0.
typeset -A parsed=()
typeset name arity
while read -r name arity; do
  parsed[$name]=$arity
done < <(awk '
  /^      -[-a-z|]*\)$/ { arm = substr($0, 7, length($0) - 7); next }
  arm != "" && $1 == "shift" {
    split(arm, names, "|")
    for (i in names) print names[i], ($2 == "" ? 0 : $2 - 1)
    arm = ""
  }
' "$ROOT/libexec/config/main.zsh")

(( ${#parsed} )) || fail 'could not read the config option arms'

for name in ${(k)parsed}; do
  if (( ${not_forwarded[(Ie)$name]} )); then continue; fi
  (( ${+SF_CONFIG_OPTIONS[$name]} )) || \
    fail "libexec/config/main.zsh parses $name but lib/options.zsh omits it"
  [[ $SF_CONFIG_OPTIONS[$name] == $parsed[$name] ]] || \
    fail "lib/options.zsh gives $name arity $SF_CONFIG_OPTIONS[$name], config takes $parsed[$name]"
done

for name in ${(k)SF_CONFIG_OPTIONS}; do
  (( ${+parsed[$name]} )) || \
    fail "lib/options.zsh declares $name but libexec/config/main.zsh does not parse it"
done

print -r -- ok
