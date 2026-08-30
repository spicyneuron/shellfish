emulate -R zsh
setopt no_aliases no_multios pipe_fail
zmodload zsh/system

typeset -g SF_SESSION_PATH=''
typeset -g SF_SESSION_LOCK=''
typeset -gA SF_SESSION=()
typeset -ga SF_SESSION_RECORDS=()
typeset -g SF_SESSION_ERROR=''
typeset -ga SF_SESSION_MATCHES=()

sf_session_fail() {
  SF_SESSION_ERROR=$1
  return 1
}

sf_session_directory() {
  local root cwd scope
  if [[ -n ${XDG_STATE_HOME-} ]]; then
    root="$XDG_STATE_HOME/shellfish/sessions"
  elif [[ -n ${HOME-} ]]; then
    root="$HOME/.local/state/shellfish/sessions"
  else
    sf_session_fail 'HOME or XDG_STATE_HOME is required when --session is omitted'
    return
  fi
  cwd=$(pwd -P) || {
    sf_session_fail 'cannot resolve the working directory'
    return
  }
  scope=$(jq -rn --arg cwd "$cwd" '$cwd | gsub("[^A-Za-z0-9]+"; "_")') &&
      [[ -n $scope ]] || {
    sf_session_fail 'cannot derive the session scope'
    return
  }
  REPLY="$root/$scope"
}

sf_session_select_path() {
  local requested=${1-} directory created
  SF_SESSION_ERROR=''
  if [[ -n $requested ]]; then
    [[ $requested == /* ]] || requested="$PWD/$requested"
    REPLY=${requested:a}
    return
  fi

  sf_session_directory || return
  directory=$REPLY
  mkdir -p "$directory" && chmod 700 "$directory" || {
    sf_session_fail "cannot prepare session directory: $directory"
    return
  }
  created=$(date -u '+%Y%m%dT%H%M%SZ') || {
    sf_session_fail 'cannot timestamp session'
    return
  }
  REPLY="$directory/$created-${sysparams[pid]}-$RANDOM$RANDOM.jsonl"
}

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

sf_session_acquire_lock() {
  local lock="${SF_SESSION_PATH}.lock"
  [[ -z $SF_SESSION_LOCK ]] || {
    sf_session_fail "session lock is already held: $SF_SESSION_LOCK"
    return
  }
  [[ -d ${SF_SESSION_PATH:h} ]] || {
    sf_session_fail "session directory does not exist: ${SF_SESSION_PATH:h}"
    return
  }
  if ! (umask 077; setopt no_clobber; : >"$lock") 2>/dev/null; then
    [[ -f $lock && ! -L $lock ]] || {
      sf_session_fail "invalid session lock: $lock"
      return
    }
  fi
  zsystem flock -t 0 -f SF_SESSION_LOCK "$lock" 2>/dev/null ||
    sf_session_fail "session is busy: $SF_SESSION_PATH"
}

sf_session_close() {
  [[ -n $SF_SESSION_LOCK ]] || return 0
  zsystem flock -u "$SF_SESSION_LOCK" 2>/dev/null || {
    sf_session_fail "cannot release session lock: $SF_SESSION_PATH"
    return
  }
  SF_SESSION_LOCK=''
  SF_SESSION=()
  SF_SESSION_RECORDS=()
}

sf_session_repair_tail() {
  local total fragment
  [[ -s $SF_SESSION_PATH && -n $(tail -c 1 "$SF_SESSION_PATH") ]] || return 0
  total=$(wc -c <"$SF_SESSION_PATH") || {
    sf_session_fail "cannot inspect session tail: $SF_SESSION_PATH"
    return
  }
  fragment=$(tail -n 1 "$SF_SESSION_PATH" | wc -c) || {
    sf_session_fail "cannot inspect session tail: $SF_SESSION_PATH"
    return
  }
  truncate -s "$(( total - fragment ))" "$SF_SESSION_PATH" || {
    sf_session_fail "cannot repair session tail: $SF_SESSION_PATH"
    return
  }
}

sf_session_prepare() {
  local runtime=$1 system_record=${2-} cwd created header id model
  SF_SESSION_ERROR=''
  [[ -z $SF_SESSION_LOCK ]] || {
    sf_session_fail "session lock is already held: $SF_SESSION_LOCK"
    return
  }
  SF_SESSION=()
  SF_SESSION_RECORDS=()
  [[ ! -e $SF_SESSION_PATH && ! -L $SF_SESSION_PATH ]] || {
    sf_session_fail "cannot create session: $SF_SESSION_PATH"
    return
  }
  cwd=$(pwd -P) && created=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
    sf_session_fail 'cannot prepare session header'
    return
  }
  header=$(jq -L "$SF_ROOT/lib" -cnce --arg cwd "$cwd" --arg created "$created" \
    --argjson runtime "$runtime" '
      include "runtime/schema";
      ({type:"session",format_version:1,cwd:$cwd,created:$created} + $runtime) |
      select(canonical_session_header(1))
    ') || {
    sf_session_fail 'cannot prepare session header'
    return
  }
  model=$(jq -er '.profile.request.model' <<<$runtime) || {
    sf_session_fail 'cannot prepare session header'
    return
  }
  id=${SF_SESSION_PATH:t}
  SF_SESSION=(
    runtime "$runtime"
    id "${id%.jsonl}"
    cwd "$cwd"
    model "$model"
    turn_id 1
  )
  SF_SESSION_RECORDS=( "$header" )
  [[ -z $system_record ]] || SF_SESSION_RECORDS+=( "$system_record" )
  printf '%s\n' "${SF_SESSION_RECORDS[@]}" | jq -L "$SF_ROOT/lib" -jes '
    include "runtime/schema";
    select(.[0] | canonical_session_header(1)) |
    select(.[1:] | canonical_session_records)
  ' >/dev/null 2>&1 || {
    SF_SESSION=()
    SF_SESSION_RECORDS=()
    sf_session_fail 'cannot prepare session records'
    return
  }
}

sf_session_create() {
  local error
  local -a records
  [[ -z $SF_SESSION_LOCK && ${#SF_SESSION_RECORDS} -gt 0 ]] || {
    sf_session_fail 'session is not prepared for creation'
    return
  }
  records=( "${SF_SESSION_RECORDS[@]}" "$@" )
  printf '%s\n' "${records[@]}" | jq -L "$SF_ROOT/lib" -jes '
    include "runtime/schema";
    select(length >= 1) |
    select(.[0] | canonical_session_header(1)) |
    select(.[1:] | canonical_session_records)
  ' >/dev/null 2>&1 || {
    sf_session_fail 'cannot prepare session records'
    return
  }
  SF_SESSION_RECORDS=( "${records[@]}" )
  if ! (setopt no_clobber; : >"$SF_SESSION_PATH") 2>/dev/null; then
    sf_session_fail "cannot create session: $SF_SESSION_PATH"
    return
  fi
  repeat 1; do
    chmod 600 "$SF_SESSION_PATH" ||
      { error="cannot secure session: $SF_SESSION_PATH"; break; }
    if ! printf '%s\n' "${records[@]}" >>"$SF_SESSION_PATH"; then
      error="cannot write session: $SF_SESSION_PATH"
      break
    fi
  done
  if [[ -z $error ]]; then
    sf_session_load || {
      error=$SF_SESSION_ERROR
      rm -f -- "$SF_SESSION_PATH" 2>/dev/null
      sf_session_fail "$error"
      return
    }
    return
  fi
  rm -f -- "$SF_SESSION_PATH" 2>/dev/null
  sf_session_fail "$error"
  return 1
}

sf_session_read_settings() {
  local session_path=$1 header second=null extracted record
  local -a fields startup
  integer count=0
  SF_SESSION_ERROR=''
  REPLY=''
  reply=()
  [[ -f $session_path && ! -L $session_path && -r $session_path ]] || {
    sf_session_fail "invalid session path: $session_path"
    return
  }
  while (( count < 2 )) && IFS= read -r record; do
    startup+=( "$record" )
    (( ++count ))
  done <"$session_path"
  (( count >= 1 )) || {
    sf_session_fail "cannot read session settings: $session_path"
    return
  }
  header=$startup[1]
  (( count < 2 )) || second=$startup[2]
  extracted=$(jq -L "$SF_ROOT/lib" -jcn --argjson header "$header" --argjson second "$second" '
    include "runtime/schema";
    def field: ., "\u0000";
    select($header | canonical_session_header(1)) |
    ($header | del(.type, .format_version, .cwd, .created) | tojson | field),
    ((if $second.type? == "system" then $second else null end) | tojson | field),
    ("ok" | field)
  ' 2>/dev/null) || {
    sf_session_fail "cannot read session settings: $session_path"
    return
  }
  fields=( "${(@0)${extracted%$'\0'}}" )
  (( ${#fields} == 3 )) && [[ $fields[3] == ok ]] || {
    sf_session_fail "cannot read session settings: $session_path"
    return
  }
  REPLY=$fields[1]
  [[ $fields[2] == null ]] || reply=( "$fields[2]" )
}

sf_session_read_runtime() {
  local session_path=$1 header
  [[ -f $session_path && ! -L $session_path && -r $session_path ]] || {
    sf_session_fail "invalid session path: $session_path"
    return
  }
  IFS= read -r header <"$session_path" || {
    sf_session_fail "cannot read session header: $session_path"
    return
  }
  REPLY=$(jq -L "$SF_ROOT/lib" -cnce --argjson header "$header" '
    include "runtime/schema";
    $header | select(canonical_session_header(1)) |
    del(.type, .format_version, .cwd, .created)
  ' 2>/dev/null) || {
    sf_session_fail "cannot read session header: $session_path"
    return
  }
}

sf_session_load() {
  local loaded record
  local -a fields
  SF_SESSION=()
  SF_SESSION_RECORDS=()
  while IFS= read -r record; do
    [[ -n $record ]] || {
      SF_SESSION_RECORDS=()
      sf_session_fail "cannot read session: $SF_SESSION_PATH"
      return
    }
    SF_SESSION_RECORDS+=( "$record" )
  done <"$SF_SESSION_PATH"
  (( ${#SF_SESSION_RECORDS} )) || {
    sf_session_fail "cannot read session: $SF_SESSION_PATH"
    return
  }
  loaded=$(printf '%s\n' "${SF_SESSION_RECORDS[@]}" | jq -L "$SF_ROOT/lib" -jes '
    include "runtime/schema";
    def field: ., "\u0000";
    select(length >= 1) |
    select(.[0] | canonical_session_header(1)) |
    select(.[1:] | canonical_session_records) |
    (.[0] | del(.type, .format_version, .cwd, .created) | tojson | field),
    (.[0].cwd | field),
    (.[0].profile.request.model | field),
    (([.[] | select(.type == "message" and .role == "user")] | length + 1) |
      tostring | field),
    ("ok" | field)
  ' 2>/dev/null) || {
    SF_SESSION_RECORDS=()
    sf_session_fail "cannot read session: $SF_SESSION_PATH"
    return
  }
  fields=( "${(@0)${loaded%$'\0'}}" )
  (( ${#fields} == 5 )) && [[ $fields[-1] == ok ]] || {
    SF_SESSION_RECORDS=()
    sf_session_fail "cannot restore session runtime: $SF_SESSION_PATH"
    return
  }
  local id=${SF_SESSION_PATH:t}
  SF_SESSION=(
    runtime "$fields[1]"
    id "${id%.jsonl}"
    cwd "$fields[2]"
    model "$fields[3]"
    turn_id "$fields[4]"
  )
}

sf_session_append() {
  local record=$1
  [[ -n $SF_SESSION_LOCK ]] || {
    sf_session_fail 'session is not open for mutation'
    return
  }
  if ! printf '%s\n' "$record" >>"$SF_SESSION_PATH"; then
    sf_session_fail "cannot append session record: $SF_SESSION_PATH"
    return
  fi
  SF_SESSION_RECORDS+=( "$record" )
}

sf_session_update() {
  local update=$1 decoded header temp error
  local -a fields
  integer changed=0
  [[ -n $SF_SESSION_LOCK && ${#SF_SESSION_RECORDS} -gt 0 ]] || {
    sf_session_fail 'session is not open for mutation'
    return
  }
  decoded=$(jq -L "$SF_ROOT/lib" -jnre --argjson header "$SF_SESSION_RECORDS[1]" \
    --argjson update "$update" '
      include "runtime/schema";
      def field: ., "\u0000";
      select($update | type == "object" and
        (keys - ["backend", "harness", "profile"] | length) == 0) |
      ($header | {type,format_version,cwd,created}) as $metadata |
      (($header | del(.type,.format_version,.cwd,.created)) * $update) as $runtime |
      ($runtime + $metadata) as $updated |
      select($updated | canonical_session_header(1)) |
      ($updated != $header | tostring | field),
      ($updated | tojson | field),
      ("ok" | field)
    ' 2>/dev/null) || {
    sf_session_fail 'invalid session update'
    return
  }
  fields=( "${(@0)${decoded%$'\0'}}" )
  (( ${#fields} == 3 )) && [[ $fields[3] == ok ]] || {
    sf_session_fail 'invalid session update'
    return
  }
  if [[ $fields[1] == false ]]; then
    REPLY=0
    return 0
  fi
  header=$fields[2]
  temp=$(mktemp "${SF_SESSION_PATH:h}/.${SF_SESSION_PATH:t}.XXXXXX") || {
    sf_session_fail "cannot prepare session update: $SF_SESSION_PATH"
    return
  }
  repeat 1; do
    chmod 600 "$temp" || {
      error="cannot secure session update: $SF_SESSION_PATH"
      break
    }
    {
      print -r -- "$header"
      (( ${#SF_SESSION_RECORDS} == 1 )) ||
        printf '%s\n' "${SF_SESSION_RECORDS[@]:1}"
    } >"$temp" || {
      error="cannot write session update: $SF_SESSION_PATH"
      break
    }
    mv -f -- "$temp" "$SF_SESSION_PATH" || {
      error="cannot replace session: $SF_SESSION_PATH"
      break
    }
    temp=''
    changed=1
  done
  if (( ! changed )); then
    rm -f -- "$temp" 2>/dev/null
    sf_session_fail "$error"
    return 1
  fi
  sf_session_load || return
  REPLY=1
}

sf_session_recover_turn() {
  local recovery record recovered=''
  local -a pending fields
  integer index
  REPLY=''
  sf_session_repair_tail || return
  sf_session_load || return
  recovery=$(printf '%s\n' "${SF_SESSION_RECORDS[@]}" | jq -jsc '
    .[1:] as $records |
    ([range(0; $records | length) |
      select($records[.].type == "message")] | last // -1) as $last |
    if $last < 0 then {recover:false,pending:[]}
    elif $records[$last].role == "user" then {recover:true,pending:[]}
    elif $records[$last].role == "assistant" then
      if $records[$last].stop == "tool_calls" then
        {recover:true,pending:[$records[$last].content[] |
          select(.type == "tool_call") | {id,name}]}
      elif any($records[$last + 1:][]; .type == "context" and .tag == "stop") then
        {recover:true,pending:[]}
      else {recover:false,pending:[]} end
    else
      ([range(0; $last) | select($records[.].role == "assistant" and
        $records[.].stop == "tool_calls")] | last) as $call_index |
      [$records[$call_index].content[] | select(.type == "tool_call") | {id,name}] as $calls |
      [$records[$call_index + 1:][] | select(.role == "tool_result") | .call_id] as $answered |
      {recover:true,pending:[$calls[] | select(.id as $id | $answered | index($id) | not)]}
    end |
    (.recover | tostring), "\u0000", (.pending[] | .id, "\u0000", .name, "\u0000"),
    "ok", "\u0000"
  ' 2>/dev/null) || {
    sf_session_fail 'cannot inspect session recovery suffix'
    return
  }
  fields=( "${(@0)${recovery%$'\0'}}" )
  (( ${#fields} >= 2 )) && [[ $fields[-1] == ok ]] || {
    sf_session_fail 'cannot inspect session recovery suffix'
    return
  }
  [[ $fields[1] == true ]] || return 0
  pending=( "${(@)fields[2,-2]}" )
  for (( index = 1; index <= ${#pending}; index += 2 )); do
    record=$(jq -cn --arg call_id "$pending[index]" --arg name "$pending[index + 1]" \
      '{type:"message",role:"tool_result",call_id:$call_id,name:$name,
       content:"tool call interrupted",exit_code:126}') || return
    sf_session_append "$record" || return
    [[ -z $recovered ]] || recovered+=$'\n'
    recovered+=$record
  done
  record='{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"Turn interrupted."}]}'
  sf_session_append "$record" || return
  [[ -z $recovered ]] || recovered+=$'\n'
  recovered+=$record
  REPLY=$recovered
}

sf_session_open() {
  local session_path=$1
  [[ -z $SF_SESSION_LOCK ]] || {
    sf_session_fail "session lock is already held: $SF_SESSION_LOCK"
    return
  }
  SF_SESSION_ERROR=''
  REPLY=''
  [[ $session_path == /* ]] || {
    sf_session_fail 'session path must be absolute'
    return
  }
  SF_SESSION_PATH=$session_path
  [[ -f $session_path && ! -L $session_path ]] || {
    sf_session_fail "invalid session path: $session_path"
    return
  }
  sf_session_acquire_lock || return
  if ! sf_session_recover_turn; then
    local error=$SF_SESSION_ERROR
    sf_session_close 2>/dev/null || true
    SF_SESSION_ERROR=$error
    return 1
  fi
}
