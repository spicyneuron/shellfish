emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -g SF_PRESENT_ERROR=''
typeset -g SF_PRESENT_RUNTIME='null'
typeset -g SF_PRESENT_IDENTITY='' SF_PRESENT_FOOTER=''

# Only the formatter tail may be live; DATA is NUL-joined private state.
typeset -ga SF_PRESENT_KIND=() SF_PRESENT_TEXT=() SF_PRESENT_DATA=()
typeset -gi SF_PRESENT_LIVE=0 SF_PRESENT_WORK_ACTIVE=0
# Rows remain here until committed to terminal scrollback.
typeset -ga SF_PRESENT_ROW_TEXT=() SF_PRESENT_ROW_SPANS=()
typeset -ga SF_PRESENT_ROW_READY=()
typeset -gi SF_PRESENT_ROW_HEAD=1
# PRIOR restores the role displaced by a retracted entry.
typeset -ga SF_PRESENT_ROLE=() SF_PRESENT_SECTION=() SF_PRESENT_PRIOR=()
typeset -ga SF_PRESENT_EMITTED=()
typeset -g SF_PRESENT_LAST_ROLE=''
typeset -gi SF_PRESENT_SECTION_ID=0
typeset -g SF_PRESENT_ASSISTANT_INDEX=''

# Refuses a second live formatter and returns the new index.
sf_tui_formatter_append() {
  local kind=$1 mode=${2:-final}
  (( ! SF_PRESENT_LIVE )) || return 1
  [[ $mode == (live|final) ]] || return 1
  [[ -n $kind ]] || return 1
  SF_PRESENT_KIND+=( "$kind" )
  SF_PRESENT_TEXT+=( '' )
  SF_PRESENT_DATA+=( '' )
  SF_PRESENT_ROLE+=( '' )
  SF_PRESENT_SECTION+=( '' )
  SF_PRESENT_PRIOR+=( '' )
  SF_PRESENT_EMITTED+=( 0 )
  REPLY=${#SF_PRESENT_KIND}
  [[ $mode == final ]] || SF_PRESENT_LIVE=$REPLY
}

# Only the first formatter in a role run owns its rule.
sf_tui_formatter_role() {
  integer index=$1
  local role=$2
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  [[ -z $SF_PRESENT_ROLE[index] ]] || return 1
  [[ -n $role ]] || return 1
  [[ $SF_PRESENT_LAST_ROLE != $role ]] || return 0
  SF_PRESENT_ROLE[index]=$role
  SF_PRESENT_PRIOR[index]=$SF_PRESENT_LAST_ROLE
  if [[ $role == (user|agent) ]]; then
    (( ++SF_PRESENT_SECTION_ID ))
    SF_PRESENT_SECTION[index]=$SF_PRESENT_SECTION_ID
  fi
  SF_PRESENT_LAST_ROLE=$role
}

sf_tui_formatter_settle() {
  (( SF_PRESENT_LIVE )) || return 1
  SF_PRESENT_LIVE=0
}

sf_tui_formatter_pending() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE == index && index > 0 )) &&
    [[ $SF_PRESENT_KIND[index] == $1 ]]
}

# Retracting an unrendered role releases its section number.
sf_tui_formatter_retract() {
  integer index=${#SF_PRESENT_KIND}
  (( index && SF_PRESENT_LIVE == index )) || return 1
  (( ! SF_PRESENT_EMITTED[index] )) || return 1
  if [[ -n $SF_PRESENT_ROLE[index] ]]; then
    [[ -z $SF_PRESENT_SECTION[index] ]] || (( --SF_PRESENT_SECTION_ID ))
    SF_PRESENT_LAST_ROLE=$SF_PRESENT_PRIOR[index]
  fi
  SF_PRESENT_LIVE=0
  sf_tui_formatter_keep 1 $(( index - 1 ))
}

sf_tui_formatter_drop() {
  integer count=$1 total=${#SF_PRESENT_KIND}
  (( count >= 0 && count <= total )) || return 1
  (( count )) || return 0
  (( ! SF_PRESENT_LIVE || SF_PRESENT_LIVE > count )) || return 1
  sf_tui_formatter_keep $(( count + 1 )) $total
  (( ! SF_PRESENT_LIVE )) || (( SF_PRESENT_LIVE -= count ))
}

# Advance settled source while retaining its rows for terminal commit.
sf_tui_formatter_advance() {
  integer source=$1 leading=$2 body_rows=$3
  local kind state continuation record
  (( ${#SF_PRESENT_KIND} )) || return 1
  kind=$SF_PRESENT_KIND[1]
  [[ $kind == (message|reasoning) ]] || return 1
  record=$SF_PRESENT_TEXT[1]
  (( source >= 0 && source <= ${#record} )) || return 1
  (( ! source )) || SF_PRESENT_TEXT[1]=${record[source + 1,-1]}
  (( ! leading )) || {
    SF_PRESENT_ROLE[1]=''
    SF_PRESENT_SECTION[1]=''
    SF_PRESENT_PRIOR[1]=''
  }
  # A resize rescans from the state reached by the settled prefix.
  sf_tui_formatter_data 1 3 || return 1
  state=$REPLY
  sf_tui_formatter_data 1 6 || return 1
  continuation=$REPLY
  sf_tui_formatter_set_field 1 2 0 || return 1
  sf_tui_formatter_set_field 1 4 '' || return 1
  sf_tui_formatter_set_field 1 8 "$state" || return 1
  sf_tui_formatter_set_field 1 9 "$continuation" || return 1
  (( ! leading )) || sf_tui_formatter_set_field 1 5 1 || return 1
  [[ $kind == reasoning ]] || return 0
  sf_tui_formatter_data 1 11 || return 1
  sf_tui_formatter_set_field 1 11 $(( REPLY + body_rows ))
}

# Keep all per-entry arrays aligned.
sf_tui_formatter_keep() {
  integer first=$1 last=$2
  local name
  local -a values
  for name in SF_PRESENT_KIND SF_PRESENT_TEXT SF_PRESENT_DATA SF_PRESENT_ROLE \
      SF_PRESENT_SECTION SF_PRESENT_PRIOR SF_PRESENT_EMITTED; do
    values=( "${(@P)name}" )
    if (( last < first || first > ${#values} )); then
      set -A "$name"
    else
      set -A "$name" "${(@)values[first,last]}"
    fi
  done
}

sf_tui_reset() {
  SF_PRESENT_LIVE=0
  SF_PRESENT_WORK_ACTIVE=0
  sf_tui_formatter_keep 1 0
  SF_PRESENT_ROW_TEXT=()
  SF_PRESENT_ROW_SPANS=()
  SF_PRESENT_ROW_READY=()
  SF_PRESENT_ROW_HEAD=1
  SF_PRESENT_LIVE_ROW_TEXT=()
  SF_PRESENT_LIVE_ROW_SPANS=()
  SF_PRESENT_LAST_ROLE=''
  SF_PRESENT_SECTION_ID=0
  SF_PRESENT_ASSISTANT_INDEX=''
}

sf_tui_formatter_set_data() {
  integer index=$1
  shift
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  SF_PRESENT_DATA[index]=${(pj:\0:)@}
}

# Writing past the end grows the private data fields.
sf_tui_formatter_set_field() {
  integer index=$1 field=$2
  local value=$3
  local -a fields
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  (( field > 0 )) || return 1
  fields=( "${(@ps:\0:)SF_PRESENT_DATA[index]}" )
  fields[field]=$value
  SF_PRESENT_DATA[index]=${(pj:\0:)fields}
}

sf_tui_formatter_data() {
  integer index=$1 field=$2
  local -a fields
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  fields=( "${(@ps:\0:)SF_PRESENT_DATA[index]}" )
  REPLY=${fields[field]-}
}

sf_tui_footer_usage() { SF_PRESENT_FOOTER="${SF_PRESENT_IDENTITY} · $1"; }

sf_tui_session_update() {
  SF_PRESENT_RUNTIME=$1
  SF_PRESENT_IDENTITY=$(jq -r '.backend.name + "/" + .profile.request.model' <<<"$1")
  SF_PRESENT_FOOTER=$SF_PRESENT_IDENTITY
}

# Event tuples are padded to seven fields. Unknown types fail.
# Tool status is an exit code, empty while pending, or "hidden".
sf_tui_event() {
  local type=$1 first=${2-} second=${3-} third=${4-}
  local fourth=${5-} fifth=${6-} sixth=${7-}
  integer index=${#SF_PRESENT_KIND}
  case $type in
    user)
      sf_tui_hook_interrupt || return 1
      sf_tui_activity_retract || return 1
      sf_tui_message_append user "$first" || return 1
      ;;
    system)
      sf_tui_hook_interrupt || return 1
      sf_tui_activity_retract || return 1
      sf_tui_message_append system "$first" || return 1
      ;;
    assistant_start)
      SF_PRESENT_ASSISTANT_INDEX=''
      sf_tui_hook_interrupt || return 1
      sf_tui_activity_retract || return 1
      sf_tui_message_append agent '' live || return 1
      ;;
    assistant_message_delta)
      sf_tui_assistant_stream message "$first" "$second" || return 1
      ;;
    assistant_reasoning_delta)
      sf_tui_assistant_stream reasoning "$first" "$second" "$third" || return 1
      ;;
    reasoning_tokens)
      if [[ -n $first && $index -gt 0 && $SF_PRESENT_LIVE == $index &&
          $SF_PRESENT_KIND[index] == reasoning ]]; then
        sf_tui_reasoning_tokens $index "$first" || return 1
      fi
      ;;
    assistant_reasoning_opaque|assistant_tool_call_delta)
      sf_tui_assistant_boundary "$first" || return 1
      sf_tui_activity_resume || return 1
      ;;
    assistant_end)
      SF_PRESENT_ASSISTANT_INDEX=''
      sf_tui_activity_retract || return 1
      sf_tui_assistant_close || return 1
      ;;
    activity_start)
      sf_tui_activity_start || return 1
      ;;
    activity_stop)
      sf_tui_activity_stop || return 1
      ;;
    hook_call)
      sf_tui_hook_call "$first" "$second" "$third" "$fourth" || return 1
      ;;
    hook_result)
      sf_tui_hook_result "$first" "$second" "$third" "$fourth" "$fifth" || return 1
      ;;
    error)
      if (( SF_PRESENT_LIVE == index && index > 0 )); then
        case $SF_PRESENT_KIND[index] in
          tool) sf_tui_tool_abandon || return 1 ;;
          hook) sf_tui_hook_abandon || return 1 ;;
        esac
      fi
      sf_tui_error_append "$first" "$second" || return 1
      ;;
    tool_call)
      sf_tui_tool_call "$first" "$second" "$third" "$fourth" || return 1
      ;;
    tool_result)
      sf_tui_tool_result "$first" "$second" "$third" "$fourth" || return 1
      ;;
    tool_permission)
      sf_tui_tool_permission || return 1
      ;;
    tool_permission_clear)
      sf_tui_tool_permission_clear || return 1
      ;;
    *) return 1 ;;
  esac
}

sf_tui_assistant_close() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE )) || return 0
  (( SF_PRESENT_LIVE == index )) || return 1
  [[ $SF_PRESENT_KIND[index] == (message|reasoning) ]] || return 1
  if (( SF_PRESENT_EMITTED[index] )) || [[ $SF_PRESENT_TEXT[index] == *[!$'\n']* ]]; then
    sf_tui_formatter_settle
  else
    sf_tui_formatter_retract
  fi
}

# Source or visible-kind transitions close the prior block.
sf_tui_assistant_boundary() {
  local source_index=$1 kind=${2-}
  integer index=${#SF_PRESENT_KIND}
  sf_tui_activity_retract || return 1
  if [[ $SF_PRESENT_ASSISTANT_INDEX != $source_index ]] ||
      { (( SF_PRESENT_LIVE )) && [[ -n $kind && $SF_PRESENT_KIND[index] != $kind ]]; }; then
    sf_tui_assistant_close || return 1
    SF_PRESENT_ASSISTANT_INDEX=$source_index
  fi
}

sf_tui_assistant_stream() {
  local kind=$1 source_index=$2 text=${3-} exact=${4-}
  integer index
  sf_tui_assistant_boundary "$source_index" "$kind" || return 1
  index=${#SF_PRESENT_KIND}
  if (( ! SF_PRESENT_LIVE )); then
    if [[ $kind == message ]]; then
      sf_tui_message_append agent '' live || return 1
    else
      sf_tui_reasoning_append live || return 1
    fi
    index=$REPLY
  fi
  [[ $SF_PRESENT_KIND[index] == $kind ]] || return 1
  if [[ -n $text ]]; then
    sf_tui_safe "$text"
    SF_PRESENT_TEXT[index]+=$REPLY
    [[ $kind != reasoning ]] || sf_tui_reasoning_grow $index ${#REPLY} || return 1
  fi
  [[ $kind != reasoning || -z $exact ]] || sf_tui_reasoning_tokens $index "$exact"
}

sf_tui_reload() {
  local session_path=$1 events
  local -a fields
  integer complete=0 index
  SF_PRESENT_ERROR=''
  [[ -f $session_path && ! -L $session_path ]] || {
    SF_PRESENT_ERROR="invalid session path: $session_path"; return 1; }
  events=$(sf_jq -jRs -f "$SF_ROOT/libexec/tui/transcript-decode.jq" \
    <"$session_path" 2>/dev/null) || {
    SF_PRESENT_ERROR="cannot read session: $session_path"; return 1; }
  fields=( "${(@0)${events%$'\0'}}" )
  sf_tui_reset
  for (( index = 1; index + 6 <= ${#fields}; index += 7 )); do
    if [[ $fields[index] == batch_ok ]]; then
      complete=1
    elif [[ $fields[index] == session_update ]]; then
      sf_tui_session_update "$fields[index + 1]"
    elif [[ $fields[index] == turn_usage ]]; then
      sf_tui_footer_usage "$fields[index + 1]"
    else
      sf_tui_event "${(@)fields[index,index + 6]}" || {
        SF_PRESENT_ERROR='cannot build presentation transcript'; return 1; }
    fi
  done
  (( complete )) || { SF_PRESENT_ERROR="cannot read session: $session_path"; return 1; }
}
