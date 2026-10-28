#!/usr/bin/env zsh

emulate -R zsh
setopt extended_glob no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_SHARE=$SF_ROOT/share

source "$SF_ROOT/lib/cli.zsh"
source "$SF_ROOT/lib/environment.zsh"

# Copy the template into the Shellfish directory, keeping existing files.
sf_init_main() {
  local dir file target template=$SF_SHARE/template
  (( ! $# )) || { sf_die "unknown argument: $1"; return 2; }
  sf_environment_dir || { sf_die "$SF_ENVIRONMENT_ERROR"; return 1; }
  dir=$REPLY
  umask 077
  for file in $template/**/*(.DN); do
    target=$dir/${${file#$template/}/#example.env/.env}
    if [[ -e $target || -L $target ]]; then
      print -r -- "kept  $target"
      continue
    fi
    mkdir -p -- "${target:h}" && cp -- "$file" "$target" ||
      { sf_die "cannot write $target"; return 1; }
    print -r -- "wrote $target"
  done
  print -r -- "Next: name a model in $dir/models/default.jsonc and add its key to $dir/.env"
}

sf_init_main "$@"
