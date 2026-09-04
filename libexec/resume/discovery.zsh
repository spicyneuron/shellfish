emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_session_directory] )) || source "$SF_ROOT/lib/session/main.zsh"

typeset -ga SF_SESSION_MATCHES=()

# Finds sessions for the current directory, newest first, up to a nonzero LIMIT.
sf_session_find() {
  local limit=${1:-0} directory cwd file field
  local -a candidates headers readable fields
  local -A header_by_file
  integer decoded=0 index
  SF_SESSION_ERROR=''
  SF_SESSION_MATCHES=()
  sf_session_directory || return
  directory=$REPLY
  cwd=$(pwd -P) || {
    sf_session_fail 'cannot resolve the working directory'
    return
  }
  candidates=( $directory/*.jsonl(N.om) )
  for file in $candidates; do
    [[ -f $file && -r $file && ! -L $file ]] && readable+=( "$file" )
  done
  if (( ${#readable} )); then
    fields=( "${(@0)$(awk 'FNR == 1 {
      printf "%s%c%s%c", FILENAME, 0, $0, 0
      nextfile
    }' "${readable[@]}" 2>/dev/null)}" )
    [[ -n $fields[-1] ]] || fields[-1]=()
    for (( index = 1; index < ${#fields}; index += 2 )); do
      header_by_file[$fields[index]]=$fields[index+1]
    done
  fi
  for file in $candidates; do
    field=${header_by_file[$file]:-null}
    headers+=( "$field" )
  done
  if (( ${#candidates} )); then
    while IFS= read -r -d '' file; do
      if [[ $file == ok ]]; then
        decoded=1
      else
        SF_SESSION_MATCHES+=( "$file" )
      fi
    done < <(printf '%s\n' "${headers[@]}" |
      jq -jRn --arg cwd "$cwd" --argjson limit "$limit" --args '
        [inputs | fromjson? // null] as $headers |
        [$ARGS.positional | to_entries[] |
          select($headers[.key] |
            type == "object" and .type == "session" and .format_version == 1 and
            (.cwd == $cwd) and
            (.profile.request.model | type == "string")) |
          .value] |
        (if $limit > 0 then .[0:$limit] else . end) |
        (.[] | ., "\u0000"), "ok", "\u0000"
      ' "${candidates[@]}" 2>/dev/null)
    (( decoded )) || {
      SF_SESSION_MATCHES=()
      sf_session_fail "cannot inspect sessions in $directory"
      return
    }
  fi
  (( ${#SF_SESSION_MATCHES} )) || sf_session_fail "no sessions match $cwd"
}
