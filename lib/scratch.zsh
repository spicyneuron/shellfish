emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_environment_dir] )) || source "$SF_ROOT/lib/environment.zsh"

sf_scratch_root() {
  local root
  sf_environment_dir || return 1
  root=$REPLY/scratch
  (umask 077; mkdir -p -- "$root") 2>/dev/null || return 1
  [[ -d $root && ! -L $root && -O $root ]] || return 1
  chmod 700 "$root" || return 1
  REPLY=$root
}

# Create a private scratch file, or with -d a directory, named after PREFIX.
sf_scratch() {
  local -a flags=()
  [[ $1 != -d ]] || { flags=( -d ); shift }
  sf_scratch_root || return 1
  REPLY=$(mktemp "${flags[@]}" "$REPLY/$1.XXXXXX") || return 1
  REPLY=${REPLY:A}
}
