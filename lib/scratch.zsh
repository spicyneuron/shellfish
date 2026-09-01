emulate -R zsh
setopt no_aliases no_multios pipe_fail

sf_temp_directory() {
  local mode=$1 fallback=${2:-${TMPDIR:-/tmp}} directory
  case $mode in
    environment) directory=$fallback ;;
    native)
      if [[ $OSTYPE == darwin* ]]; then
        directory=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR) || return 1
      else
        directory=$fallback
      fi
      ;;
    *) return 1 ;;
  esac
  [[ -d $directory ]] || return 1
  REPLY=${directory:A}
}

sf_scratch_category() {
  local category=$1 root
  [[ -n $category && $category != *[^A-Za-z0-9]* ]] || return 1
  sf_temp_directory environment || return 1
  root="$REPLY/shellfish-$EUID"
  if [[ -e $root || -L $root ]]; then
    [[ -d $root && ! -L $root && -O $root ]] || return 1
  else
    (umask 077; mkdir -- "$root") || return 1
  fi
  chmod 700 "$root" || return 1
  REPLY="$root/$category"
  if [[ -e $REPLY || -L $REPLY ]]; then
    [[ -d $REPLY && ! -L $REPLY && -O $REPLY ]] || return 1
  else
    (umask 077; mkdir -- "$REPLY") || return 1
  fi
  chmod 700 "$REPLY" || return 1
}

sf_scratch_directory() {
  local category=$1 name=$2 directory
  [[ -n $name && $name != . && $name != .. && $name != */* ]] || return 1
  sf_scratch_category "$category" || return 1
  directory="$REPLY/$name"
  if [[ -e $directory || -L $directory ]]; then
    [[ -d $directory && ! -L $directory && -O $directory ]] || return 1
  else
    (umask 077; mkdir -- "$directory") || return 1
  fi
  chmod 700 "$directory" || return 1
  REPLY=${directory:A}
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
