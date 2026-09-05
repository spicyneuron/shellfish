#!/usr/bin/env zsh

# Each directory under libexec/ is an independent component. It may use shared
# implementation under lib/, bundled data, and the public shellfish commands,
# but it must not reach into another component. This check enumerates every
# repository path, jq include, shellfish command, and sf_*/SF_* symbol each
# component references, then names anything it neither owns nor shares.

source "${0:A:h:h}/_helpers.zsh"

typeset -r symbol_pattern='\b(SF_[A-Za-z0-9_]+|sf_[a-z0-9_]+)\b'
typeset -r declare_pattern='^[[:space:]]*(sf_[a-z0-9_]+\(\)|(typeset|local|integer|float|export|readonly)[^;]*)'

typeset -a matches symbols
# Unique matches of a pattern across files, tolerating no files and no match.
collect() {
  local pattern=$1 found=''
  shift
  (( ! $# )) || found=$(grep -hoE "$pattern" "$@") || found=''
  matches=( ${(fu)found} )
}

# Symbols a set of files declares, as function definitions and the names on
# declaration keywords.
declarations() {
  local found=''
  (( ! $# )) || found=$(grep -hoE "$declare_pattern" "$@" | grep -oE "$symbol_pattern") || found=''
  symbols=( ${(fu)found} )
}

typeset dir component module token cmd
typeset -a shell_files jq_files routes=()

# Shared implementation is available to every component by definition.
declarations $ROOT/lib/**/*.zsh(.N)
typeset -A shared=()
for token in $symbols; do shared[$token]=1; done
(( ${#shared} )) || fail 'no shared declarations found'

# The public command grammar is read from the dispatcher rather than restated.
collect '^[[:space:]]+[a-z|-]+\)' "$ROOT/bin/shellfish"
for token in $matches; do routes+=( ${(s:|:)${${token//[[:space:]]/}%\)}} ); done
(( ${#routes} )) || fail 'no dispatcher routes found'

for dir in $ROOT/libexec/*(/N); do
  component=${dir:t}
  shell_files=( $dir/**/*.zsh(.N) )
  jq_files=( $dir/**/*.jq(.N) )
  (( ${#shell_files} )) || fail "no sources found for component: $component"

  # 1. Every repository path, sourced or executed, is owned, shared, or data.
  collect '\$SF_ROOT/[^"'\'' ]+' $shell_files $jq_files
  for token in $matches; do
    module=${token#\$SF_ROOT/}
    [[ $module == (libexec/$component/*|bin/shellfish|lib/*|default/*|template/*) ]] ||
      fail "$component uses a file it does not own: $module"
  done

  # 2. jq includes resolve to canonical definitions or the component's own.
  collect '^include "[^"]+"' $jq_files
  for token in $matches; do
    module=${${token#include \"}%\"}
    [[ $module == (libexec/$component/*|lib/*) ]] ||
      fail "$component includes jq it does not own: $module"
  done

  # 3. Components reach each other only through public commands. An option
  # rather than a command routes to the TUI, which owns its own validation.
  collect '"\$SF_ENTRY" [a-z][a-z-]*' $shell_files
  for token in $matches; do
    cmd=${token##* }
    (( ${routes[(Ie)$cmd]} )) ||
      fail "$component invokes an unknown shellfish command: $cmd"
  done

  # 4. Every referenced symbol is declared by the component or by lib/.
  declarations $shell_files
  typeset -A declared=()
  for token in $symbols; do declared[$token]=1; done
  collect "$symbol_pattern" $shell_files $jq_files
  (( ${#matches} )) || fail "no symbols found for component: $component"
  for token in $matches; do
    (( ${+declared[$token]} || ${+shared[$token]} )) ||
      fail "$component references a symbol it does not own: $token"
  done
done
