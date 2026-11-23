sf_file_write() {
  setopt local_options no_err_exit
  local tool=$1 file_path=$2 content=$3 scratch diff
  local -i existed=0 diff_status=0
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-file-diff.XXXXXX") || {
    printf '%s: cannot prepare diff for %s\n' "$tool" "$file_path"
    return 2
  }
  scratch=${scratch:A}
  {
    [[ ! -e $file_path && ! -L $file_path ]] || existed=1
    if ! { if (( existed )); then cat -- "$file_path"; fi } >"$scratch/before" ||
       ! printf '%s' "$content" >"$scratch/after"; then
      printf '%s: cannot prepare diff for %s\n' "$tool" "$file_path"
      return 2
    fi
    cat -- "$scratch/after" >"$file_path" || {
      printf '%s: cannot write %s\n' "$tool" "$file_path"
      return 2
    }
    diff=$(GIT_DIR="$scratch/.git" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_COUNT=0 GIT_CONFIG_PARAMETERS='' git -C "$scratch" \
      diff --no-index --no-color --no-ext-diff --no-textconv --text --unified=1 \
      -- before after) || diff_status=$?
    if (( diff_status == 0 )); then
      (( ! existed )) || printf '%s: %s is already up to date\n' "$tool" "$file_path"
    elif (( diff_status == 1 )) && [[ $diff == *$'\n@@ '* ]]; then
      printf '@@ %s\n' "${diff#*$'\n@@ '}"
    else
      printf '%s: cannot render diff for %s\n' "$tool" "$file_path"
      return 2
    fi
  } always {
    rm -rf -- "$scratch"
  }
}
