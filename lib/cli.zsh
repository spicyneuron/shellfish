sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

# Condense captured output into one line to append to a message that already
# names the file. jq's own "jq: " prefix would only repeat that attribution.
sf_cli_diagnostic() {
  local output=$1 detail=''
  [[ -z $output ]] || \
    detail=$(print -rn -- "$output" | LC_ALL=C tr -s '[:cntrl:]' ' ' | cut -c 1-1000)
  REPLY=${detail#jq: }
}

# An inherited pipe may never reach EOF, so argv input only probes stdin for
# an immediately available conflict.
sf_cli_read_prompt() {
  local input=''
  if (( $# )); then
    if [[ ! -t 0 ]]; then IFS= read -t 0 -r input || true; fi
    [[ -z $input ]] || {
      sf_die 'cannot use a message argument and standard input together'
      return 2
    }
    input=${(j: :)@}
  elif [[ ! -t 0 ]]; then
    input=$(<&0)
  fi
  REPLY=$input
}

sf_cli_require_terminal() {
  local name=$1
  if [[ ! -o interactive ]]; then
    sf_die "$name requires an interactive terminal"
    return 2
  fi
  if [[ ! -t 0 ]]; then
    exec </dev/tty || { sf_die "$name requires an interactive terminal"; return 2; }
  fi
  if [[ ! -t 1 ]]; then sf_die "$name requires an interactive terminal"; return 2; fi
}
