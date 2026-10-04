emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_environment_state_dir] )) || source "$SF_ROOT/lib/environment.zsh"

sf_scratch_root() {
  local root
  if [[ -n ${SHELLFISH_SCRATCH_DIR-} ]]; then
    root=${SHELLFISH_SCRATCH_DIR:A}
  else
    sf_environment_state_dir || return 1
    root=${REPLY:A}/scratch
  fi
  (umask 077; mkdir -p -- "$root") 2>/dev/null || return 1
  [[ -d $root && ! -L $root && -O $root ]] || return 1
  chmod 700 "$root" || return 1
  REPLY=$root
}

sf_scratch_directory() {
  local prefix=$1 created
  [[ -n $prefix && $prefix != *[^A-Za-z0-9_-]* ]] || return 1
  sf_scratch_root || return 1
  created=$(mktemp -d "$REPLY/$prefix.XXXXXX") || return 1
  chmod 700 "$created" || {
    rm -rf -- "$created"
    return 1
  }
  REPLY=${created:A}
}

sf_scratch_file() {
  local prefix=$1 created
  [[ -n $prefix && $prefix != *[^A-Za-z0-9_-]* ]] || return 1
  sf_scratch_root || return 1
  created=$(mktemp "$REPLY/$prefix.XXXXXX") || return 1
  chmod 600 "$created" || {
    rm -f -- "$created"
    return 1
  }
  REPLY=${created:A}
}
