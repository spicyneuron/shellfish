emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -gA SF_SESSION=()
typeset -ga SF_SESSION_RECORDS=()
typeset -gA SF_HOOK_COUNTS=()
typeset -g SF_SESSION_ERROR=''
typeset -g SF_SESSION_RECOVERY_NEEDED=''
typeset -ga SF_SESSION_PENDING_CALL=()

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

sf_session_reset() {
  SF_SESSION=()
  SF_SESSION_RECORDS=()
  SF_HOOK_COUNTS=()
  SF_SESSION_RECOVERY_NEEDED=''
  SF_SESSION_PENDING_CALL=()
}

sf_session_repair_tail() {
  local session_path=$1 total fragment
  [[ -s $session_path && -n $(tail -c 1 "$session_path") ]] || return 0
  total=$(wc -c <"$session_path") || {
    sf_session_fail "cannot inspect session tail: $session_path"
    return
  }
  fragment=$(tail -n 1 "$session_path" | wc -c) || {
    sf_session_fail "cannot inspect session tail: $session_path"
    return
  }
  truncate -s "$(( total - fragment ))" "$session_path" || {
    sf_session_fail "cannot repair session tail: $session_path"
    return
  }
}

sf_session_prepare() {
  local runtime=$1 cwd created decoded header model
  SF_SESSION_ERROR=''
  sf_session_reset
  cwd=$(pwd -P) && created=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
    sf_session_fail 'cannot prepare session header'
    return
  }
  decoded=$(sf_jq -jnre --arg cwd "$cwd" --arg created "$created" \
    --argjson runtime "$runtime" '
      include "lib/runtime/schema";
      def field: ., "\u0000";
      ({type:"session",format_version:1,cwd:$cwd,created:$created} + $runtime) |
      select(canonical_session_header(1)) |
      (tojson | field),
      (.profile.request.model | field),
      (hook_names[] as $hook |
        ($hook | field), (.harness[$hook] // [] | length | tostring | field)),
      ("ok" | field)
    ') || {
    sf_session_fail 'cannot prepare session header'
    return
  }
  local -a fields=( "${(@0)${decoded%$'\0'}}" )
  (( ${#fields} >= 5 && (${#fields} - 3) % 2 == 0 )) && [[ $fields[-1] == ok ]] || {
    sf_session_fail 'cannot prepare session header'
    return
  }
  header=$fields[1]
  model=$fields[2]
  integer index
  for (( index = 3; index < ${#fields}; index += 2 )); do
    SF_HOOK_COUNTS[$fields[index]]=$fields[index+1]
  done
  SF_SESSION=(
    runtime "$runtime"
    cwd "$cwd"
    model "$model"
    turn_id 1
  )
  SF_SESSION_RECORDS=( "$header" )
}

# Adds a materialized system record to a prepared session.
sf_session_system() {
  local content=${1-} record
  SF_SESSION_ERROR=''
  [[ -n $content ]] || return 0
  record=$(jq -cn --arg content "$content" '{type:"system",content:$content}') ||
    sf_session_fail 'cannot prepare system record' || return
  SF_SESSION_RECORDS+=( "$record" )
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
  REPLY=$(sf_jq -cnce --argjson header "$header" '
    include "lib/runtime/schema";
    $header | select(canonical_session_header(1)) |
    del(.type, .format_version, .cwd, .created)
  ' 2>/dev/null) || {
    sf_session_fail "cannot read session header: $session_path"
    return
  }
}

# Derives session state from the records already held in memory.
sf_session_project() {
  local session_path=$1 loaded
  local -a fields
  SF_SESSION=()
  SF_HOOK_COUNTS=()
  SF_SESSION_RECOVERY_NEEDED=''
  SF_SESSION_PENDING_CALL=()
  loaded=$(printf '%s\n' "${SF_SESSION_RECORDS[@]}" | sf_jq -jes '
    include "lib/runtime/schema";
    def field: ., "\u0000";
    select(length >= 1) |
    select(.[0] | canonical_session_header(1)) |
    (.[1:] | session_records_state) as $state |
    select($state.valid) |
    (.[0] | del(.type, .format_version, .cwd, .created) | tojson | field),
    (.[0].cwd | field),
    (.[0].profile.request.model | field),
    (([.[] | select(.type == "user")] | length + 1) |
      tostring | field),
    ($state.messages > 0 and $state.next != "user" | tostring | field),
    ($state.call.id // "" | field),
    ($state.call.name // "" | field),
    (hook_names[] as $hook |
      ($hook | field), (.[0].harness[$hook] // [] | length | tostring | field)),
    ("ok" | field)
  ' 2>/dev/null) || {
    sf_session_fail "cannot read session: $session_path"
    return
  }
  fields=( "${(@0)${loaded%$'\0'}}" )
  (( ${#fields} >= 8 && (${#fields} - 8) % 2 == 0 )) &&
      [[ $fields[5] == (true|false) && $fields[-1] == ok ]] || {
    sf_session_fail "cannot restore session runtime: $session_path"
    return
  }
  integer index
  SF_SESSION_RECOVERY_NEEDED=$fields[5]
  [[ -z $fields[6] ]] || SF_SESSION_PENDING_CALL=( "$fields[6]" "$fields[7]" )
  for (( index = 8; index < ${#fields}; index += 2 )); do
    SF_HOOK_COUNTS[$fields[index]]=$fields[index+1]
  done
  SF_SESSION=(
    runtime "$fields[1]"
    cwd "$fields[2]"
    model "$fields[3]"
    turn_id "$fields[4]"
  )
}

# Replaces the in-memory view with the session and any continuation records. Never writes.
sf_session_read() {
  local session_path=$1 input record
  sf_session_reset
  for input in "$@"; do
    while IFS= read -r record; do
      [[ -n $record ]] || {
        SF_SESSION_RECORDS=()
        sf_session_fail "cannot read session: $session_path"
        return
      }
      SF_SESSION_RECORDS+=( "$record" )
    done <"$input"
  done
  (( ${#SF_SESSION_RECORDS} )) || {
    sf_session_fail "cannot read session: $session_path"
    return
  }
  sf_session_project "$session_path" || {
    SF_SESSION_RECORDS=()
    return 1
  }
}

sf_session_append() {
  local session_path=$1 record=$2
  (( ${#SF_SESSION_RECORDS} )) || {
    sf_session_fail 'session has not been read'
    return
  }
  if ! printf '%s\n' "$record" >>"$session_path"; then
    sf_session_fail "cannot append session record: $session_path"
    return
  fi
  SF_SESSION_RECORDS+=( "$record" )
  SF_SESSION_RECOVERY_NEEDED=''
  SF_SESSION_PENDING_CALL=()
}

sf_session_update() {
  local session_path=$1 update=$2 decoded header temp error
  local -a fields
  integer changed=0
  (( ${#SF_SESSION_RECORDS} )) || {
    sf_session_fail 'session has not been read'
    return
  }
  decoded=$(sf_jq -jnre --argjson header "$SF_SESSION_RECORDS[1]" \
    --argjson update "$update" '
      include "lib/runtime/schema";
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
  temp=$(mktemp "${session_path:h}/.${session_path:t}.XXXXXX") || {
    sf_session_fail "cannot prepare session update: $session_path"
    return
  }
  repeat 1; do
    chmod 600 "$temp" || {
      error="cannot secure session update: $session_path"
      break
    }
    {
      print -r -- "$header"
      (( ${#SF_SESSION_RECORDS} == 1 )) ||
        printf '%s\n' "${SF_SESSION_RECORDS[@]:1}"
    } >"$temp" || {
      error="cannot write session update: $session_path"
      break
    }
    mv -f -- "$temp" "$session_path" || {
      error="cannot replace session: $session_path"
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
  sf_session_read "$session_path" || return
  REPLY=1
}

# Closes an unfinished or explicitly failed turn, reporting appended records in REPLY.
# Requires a freshly read session.
# $4 holds tool_call records for queued calls that never ran. Each is closed with
# a cancelled result so the transcript still reports every call the model made.
sf_session_recover_turn() {
  local session_path=$1 message=${2:-Turn interrupted.} record result recovered='' needed
  local -a pending cancelled
  integer force_error=${3:-0}
  cancelled=( ${(f)4} )
  REPLY=''
  [[ -n $SF_SESSION_RECOVERY_NEEDED ]] || {
    sf_session_fail 'session recovery state is unavailable'
    return
  }
  needed=$SF_SESSION_RECOVERY_NEEDED
  pending=( "${SF_SESSION_PENDING_CALL[@]}" )
  SF_SESSION_RECOVERY_NEEDED=''
  SF_SESSION_PENDING_CALL=()
  REPLY=''
  [[ $needed == true || force_error -ne 0 ]] || return 0
  # Both only apply mid-batch, which is exactly when recovery is needed.
  if [[ $needed == true ]]; then
    if (( ${#pending} == 2 )); then
      record=$(jq -cn --arg call_id "$pending[1]" --arg name "$pending[2]" \
        '{type:"tool_result",call_id:$call_id,name:$name,
         content:"tool call interrupted",exit_code:126}') || return
      sf_session_append "$session_path" "$record" || return
      recovered=$record
    fi
    for record in "${cancelled[@]}"; do
      result=$(jq -cn --argjson call "$record" \
        '{type:"tool_result",call_id:$call.id,name:$call.name,
         content:"tool call cancelled",exit_code:126}') || return
      sf_session_append "$session_path" "$record" || return
      sf_session_append "$session_path" "$result" || return
      [[ -z $recovered ]] || recovered+=$'\n'
      recovered+=$record$'\n'$result
    done
  fi
  record=$(jq -cn --arg message "$message" '{type:"turn_error",message:$message}') || return
  sf_session_append "$session_path" "$record" || return
  [[ -z $recovered ]] || recovered+=$'\n'
  recovered+=$record
  REPLY=$recovered
}

# Adopts the durable transcript as the in-memory view. Repair precedes the read
# so a torn trailing line cannot fail it, and the read precedes recovery so a
# dangling turn is judged against the durable records rather than a stale view.
sf_session_resync_turn() {
  local session_path=$1 message=${2-} cancelled=${4-}
  integer force_error=${3:-0}
  sf_session_repair_tail "$session_path" || return
  sf_session_read "$session_path" || return
  sf_session_recover_turn "$session_path" "$message" "$force_error" "$cancelled"
}

sf_session_begin_turn() {
  local session_path=$1
  SF_SESSION_ERROR=''
  REPLY=''
  [[ $session_path == /* ]] || {
    sf_session_fail 'session path must be absolute'
    return
  }
  [[ -f $session_path && ! -L $session_path ]] || {
    sf_session_fail "invalid session path: $session_path"
    return
  }
  if ! sf_session_resync_turn "$session_path"; then
    sf_session_reset
    return 1
  fi
}
