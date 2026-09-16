emulate -R zsh
setopt no_aliases no_multios pipe_fail

sf_scratch_category() {
  local category=$1 directory=${TMPDIR:-/tmp} root
  [[ -n $category && $category != *[^A-Za-z0-9]* ]] || return 1
  [[ -d $directory ]] || return 1
  root="${directory:A}/shellfish-$EUID"
  (umask 077; mkdir -- "$root") 2>/dev/null || :
  [[ -d $root && ! -L $root && -O $root ]] || return 1
  chmod 700 "$root" || return 1
  REPLY="$root/$category"
  (umask 077; mkdir -- "$REPLY") 2>/dev/null || :
  [[ -d $REPLY && ! -L $REPLY && -O $REPLY ]] || return 1
  chmod 700 "$REPLY" || return 1
}

sf_scratch_create() {
  local category=$1 prefix=$2 created
  [[ -n $prefix && $prefix != *[^A-Za-z0-9_-]* ]] || return 1
  sf_scratch_category "$category" || return 1
  created=$(mktemp -d "$REPLY/$prefix.XXXXXX") || return 1
  chmod 700 "$created" || {
    rm -rf -- "$created"
    return 1
  }
  REPLY=${created:A}
}

sf_scratch_file() {
  local category=$1 prefix=$2 created
  [[ -n $prefix && $prefix != *[^A-Za-z0-9_-]* ]] || return 1
  sf_scratch_category "$category" || return 1
  created=$(mktemp "$REPLY/$prefix.XXXXXX") || return 1
  chmod 600 "$created" || {
    rm -f -- "$created"
    return 1
  }
  REPLY=${created:A}
}
