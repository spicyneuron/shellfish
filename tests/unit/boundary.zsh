#!/usr/bin/env zsh

# Components may use lib/, bundled data, and public commands, but not each other.

source "${0:A:h:h}/_helpers.zsh"

typeset -r symbol_pattern='\b(SF_[A-Za-z0-9_]+|sf_[a-z0-9_]+)\b'
typeset -r declare_pattern='^[[:space:]]*(sf_[a-z0-9_]+\(\)|(typeset|local|integer|float|export|readonly)[^;]*)'

typeset -a matches symbols
collect() {
  local pattern=$1 found=''
  shift
  (( ! $# )) || found=$(grep -hoE "$pattern" "$@") || found=''
  matches=( ${(fu)found} )
}

declarations() {
  local found=''
  (( ! $# )) || found=$(grep -hoE "$declare_pattern" "$@" | grep -oE "$symbol_pattern") || found=''
  symbols=( ${(fu)found} )
}

typeset dir component module token cmd
typeset -a shell_files jq_files routes=()
# Clients drive the core through public commands and may share only policy-free
# primitives. Canonical session reading and provider mechanics stay in the core.
typeset -a clients=( tui resume )
typeset -a client_shared=(
  lib/options.zsh lib/process.zsh lib/runtime.zsh lib/scratch.zsh lib/session.zsh )
# lib/session.zsh both names a session and mutates one. A client may name one.
typeset -a core_only_symbols=(
  sf_session_prepare sf_session_system sf_session_read sf_session_append
  sf_session_update sf_session_recover_turn sf_session_begin_turn )

# Shared code never calls upward into a program.
collect '\$SF_ROOT/libexec[^"'\'' ]*' $ROOT/lib/**/*(.N)
(( ! ${#matches} )) || fail "lib uses a program: $matches[1]"
collect '^include "libexec[^"]+"' $ROOT/lib/**/*.jq(.N)
(( ! ${#matches} )) || fail "lib includes program jq: $matches[1]"

# Collect shared symbols.
declarations $ROOT/lib/**/*.zsh(.N)
typeset -A shared=()
for token in $symbols; do shared[$token]=1; done
(( ${#shared} )) || fail 'no shared declarations found'

# Derive public command routes.
collect '^[[:space:]]+[a-z|-]+\)' "$ROOT/bin/shellfish"
for token in $matches; do routes+=( ${(s:|:)${${token//[[:space:]]/}%\)}} ); done
(( ${#routes} )) || fail 'no dispatcher routes found'

for dir in $ROOT/libexec/*(/N); do
  component=${dir:t}
  shell_files=( $dir/**/*.zsh(.N) )
  jq_files=( $dir/**/*.jq(.N) )
  (( ${#shell_files} )) || fail "no sources found for component: $component"

  # Repository paths must be owned, shared, or bundled data.
  collect '\$SF_ROOT/[^"'\'' ]+' $shell_files $jq_files
  for token in $matches; do
    module=${token#\$SF_ROOT/}
    [[ $module == (libexec/$component/*|bin/shellfish|lib/*|share) ]] ||
      fail "$component uses a file it does not own: $module"
  done
  collect '\$SF_SHARE/[^"'\'' ]+' $shell_files $jq_files
  for token in $matches; do
    module=${token#\$SF_SHARE/}
    [[ $module == (default/*|template/*) ]] ||
      fail "$component uses unknown shared data: $module"
  done

  # jq includes stay component-local, and clients own no canonical schema.
  collect '^include "[^"]+"' $jq_files
  for token in $matches; do
    module=${${token#include \"}%\"}
    [[ $module == (libexec/$component/*|lib/*) ]] ||
      fail "$component includes jq it does not own: $module"
    (( ! ${clients[(Ie)$component]} )) ||
      fail "$component includes core jq: $module"
  done

  # Clients reach the core through public commands and shared primitives only.
  if (( ${clients[(Ie)$component]} )); then
    collect '\$SF_ROOT/lib/[^"'\'' ]+' $shell_files $jq_files
    for token in $matches; do
      module=${token#\$SF_ROOT/}
      (( ${client_shared[(Ie)$module]} )) ||
        fail "$component uses core implementation: $module"
    done
    collect "$symbol_pattern" $shell_files $jq_files
    for token in $matches; do
      (( ! ${core_only_symbols[(Ie)$token]} )) ||
        fail "$component mutates a session: $token"
    done
  fi

  # Cross-component calls use public commands.
  collect '"\$SF_ENTRY" [a-z][a-z-]*' $shell_files
  for token in $matches; do
    cmd=${token##* }
    (( ${routes[(Ie)$cmd]} )) ||
      fail "$component invokes an unknown shellfish command: $cmd"
  done

  # Symbols must be local or shared.
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
