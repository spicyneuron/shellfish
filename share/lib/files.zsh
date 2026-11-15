sf_file_write() {
  setopt local_options no_err_exit
  local tool=$1 file_path=$2 content=$3 snapshot diff_file existed diff_status
  snapshot=$(mktemp "${TMPDIR:-/tmp}/shellfish-file-original.XXXXXX") || {
    printf '%s: cannot prepare diff for %s\n' "$tool" "$file_path"
    return 2
  }
  diff_file=$(mktemp "${TMPDIR:-/tmp}/shellfish-file-diff.XXXXXX") || {
    rm -f -- "$snapshot"
    printf '%s: cannot prepare diff for %s\n' "$tool" "$file_path"
    return 2
  }
  {
    if [[ -e $file_path || -L $file_path ]]; then
      cp -- "$file_path" "$snapshot" || {
        printf '%s: cannot prepare diff for %s\n' "$tool" "$file_path"
        return 2
      }
      existed=true
    else
      existed=false
    fi
    printf '%s' "$content" >"$file_path" || {
      printf '%s: cannot write %s\n' "$tool" "$file_path"
      return 2
    }
    if diff -U1 -L '' -L '' -- "$snapshot" "$file_path" >"$diff_file"; then
      diff_status=0
    else
      diff_status=$?
    fi
    case $diff_status in
      0) [[ $existed == false ]] || printf '%s: %s is already up to date\n' "$tool" "$file_path" ;;
      1)
        awk '
          NR == 1 && /^--- / { next }
          NR == 2 && /^\+\+\+ / { next }
          { print }
        ' "$diff_file"
        ;;
      *)
        printf '%s: cannot render diff for %s\n' "$tool" "$file_path"
        return 2
        ;;
    esac
  } always {
    rm -f -- "$snapshot" "$diff_file"
  }
}
