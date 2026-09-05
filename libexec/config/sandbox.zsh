emulate -R zsh
setopt no_aliases no_multios pipe_fail

sf_sandbox_detect_path() {
  local candidate=$1

  [[ -n $candidate && $candidate == /* && -e $candidate ]] || return 1
  REPLY=${candidate:A}
}

sf_sandbox_detect() {
  local output candidate cargo_home config_home home=${HOME-} origin record
  local read_json write_json
  local -a git_candidates=() read_paths=() write_paths=()
  integer git_attributes=0 git_global=0 git_ignore=0

  [[ -z $home ]] || home=${home:A}

  if (( $+commands[git] )); then
    if output=$(command git var GIT_CONFIG_GLOBAL 2>/dev/null); then
      git_global=1
      git_candidates+=( "${(@f)output}" )
    fi
    if output=$(command git var GIT_ATTR_GLOBAL 2>/dev/null); then
      git_attributes=1
      git_candidates+=( "${(@f)output}" )
    fi
    if output=$(command git config --global --includes --path --get-all core.excludesFile \
        2>/dev/null); then
      git_ignore=1
      git_candidates+=( "${(@f)output}" )
    fi
    while IFS= read -r -d '' origin && IFS= read -r -d '' record; do
      [[ $origin == file:* ]] || continue
      git_candidates+=( "${origin#file:}" )
    done < <(command git config --global --includes --show-origin --null --list 2>/dev/null || true)
    (( git_global )) || [[ -z $home ]] || git_candidates+=( "$home/.gitconfig" )
    if [[ -n ${XDG_CONFIG_HOME-} ]]; then
      config_home=${XDG_CONFIG_HOME:A}
    elif [[ -n $home ]]; then
      config_home="$home/.config"
    fi
    if [[ -n $config_home ]]; then
      (( git_global )) || git_candidates+=( "$config_home/git/config" )
      (( git_ignore )) || git_candidates+=( "$config_home/git/ignore" )
      (( git_attributes )) || git_candidates+=( "$config_home/git/attributes" )
    fi
    for candidate in "${git_candidates[@]}"; do
      sf_sandbox_detect_path "$candidate" && read_paths+=( "$REPLY" )
    done
  fi

  if (( $+commands[go] )); then
    output=$(command go env -json GOCACHE GOMODCACHE 2>/dev/null) || output=''
    if [[ -n $output ]]; then
      while IFS= read -r candidate; do
        sf_sandbox_detect_path "$candidate" && write_paths+=( "$REPLY" )
      done < <(jq -r '.GOCACHE, .GOMODCACHE | select(type == "string")' <<<"$output" 2>/dev/null)
    fi
  fi

  if (( $+commands[uv] )); then
    candidate=$(command uv cache dir 2>/dev/null) &&
      sf_sandbox_detect_path "$candidate" && write_paths+=( "$REPLY" )
  fi

  candidate=''
  if (( $+commands[python3] )); then
    candidate=$(command python3 -m pip cache dir 2>/dev/null) || candidate=''
  fi
  if [[ -z $candidate ]] && (( $+commands[python] )); then
    candidate=$(command python -m pip cache dir 2>/dev/null) || candidate=''
  fi
  if [[ -n $candidate ]] && sf_sandbox_detect_path "$candidate"; then
    write_paths+=( "$REPLY" )
  fi

  if (( $+commands[npm] )); then
    candidate=$(command npm config get cache 2>/dev/null) &&
      sf_sandbox_detect_path "$candidate" && write_paths+=( "$REPLY" )
  fi

  if (( $+commands[pnpm] )); then
    candidate=$(command pnpm store path 2>/dev/null) &&
      sf_sandbox_detect_path "$candidate" && write_paths+=( "$REPLY" )
  fi

  if (( $+commands[rustc] )); then
    candidate=$(command rustc --print sysroot 2>/dev/null) &&
      sf_sandbox_detect_path "$candidate" && read_paths+=( "$REPLY" )
  fi
  if (( $+commands[cargo] )); then
    if [[ -n ${CARGO_HOME-} ]]; then
      cargo_home=$CARGO_HOME
    elif [[ -n ${HOME-} ]]; then
      cargo_home="$HOME/.cargo"
    fi
    if [[ -n $cargo_home ]]; then
      for candidate in "$cargo_home/registry" "$cargo_home/git"; do
        sf_sandbox_detect_path "$candidate" && write_paths+=( "$REPLY" )
      done
      for candidate in "$cargo_home/.package-cache" "$cargo_home/.package-cache-mutate" \
        "$cargo_home/.global-cache"; do
        sf_sandbox_detect_path "$candidate" && write_paths+=( "$REPLY" )
      done
    fi
  fi

  read_json=$(jq -cn '$ARGS.positional | unique' --args -- "${read_paths[@]}") || return
  write_json=$(jq -cn '$ARGS.positional | unique' --args -- "${write_paths[@]}") || return
  jq -n --argjson read "$read_json" --argjson write "$write_json" \
    '{sandbox_read_paths:$read,sandbox_write_paths:$write}'
}
