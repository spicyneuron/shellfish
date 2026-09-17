#!/usr/bin/env zsh

# Derive runtime option arity and compare it with the forwarding table.

source "${0:A:h:h}/_helpers.zsh"
sf_test_source lib/options.zsh

typeset -a not_forwarded=( -- --verbose )

# A shift count includes the option itself.
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
' "$ROOT/lib/runtime.zsh")

(( ${#parsed} )) || fail 'could not read the runtime option arms'

for name in ${(k)parsed}; do
  if (( ${not_forwarded[(Ie)$name]} )); then continue; fi
  (( ${+SF_CREATE_OPTIONS[$name]} )) || \
    fail "lib/runtime.zsh parses $name but lib/options.zsh omits it"
  [[ $SF_CREATE_OPTIONS[$name] == $parsed[$name] ]] || \
    fail "lib/options.zsh gives $name arity $SF_CREATE_OPTIONS[$name], runtime takes $parsed[$name]"
done

for name in ${(k)SF_CREATE_OPTIONS}; do
  [[ $name == (--system|--system-file) ]] || (( ${+parsed[$name]} )) || \
    fail "lib/options.zsh declares $name but lib/runtime.zsh does not parse it"
done
[[ $SF_CREATE_OPTIONS[--system] == 1 && $SF_CREATE_OPTIONS[--system-file] == 1 ]] ||
  fail 'creation options give system inputs the wrong arity'

print -r -- ok
