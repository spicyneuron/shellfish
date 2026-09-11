emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

# The presentation input boundary. The controller and transcript replay both feed
# normalized events here, and sf_tui_event is the only caller that may drive the
# formatter list below.

typeset -g SF_PRESENT_ERROR=''
# The frozen session runtime, refreshed by live session updates.
typeset -g SF_PRESENT_RUNTIME='null'
typeset -g SF_PRESENT_IDENTITY='' SF_PRESENT_FOOTER=''

# One ordered list of formatters awaiting commitment. At most the tail is live;
# every earlier entry is final and can only be dropped once committed. KIND
# selects the owning formatter and TEXT is the logical content it has left to
# render, which a successful commit consumes. DATA is whatever else that formatter
# needs, NUL-joined and opaque here.
typeset -ga SF_PRESENT_KIND=() SF_PRESENT_TEXT=() SF_PRESENT_DATA=()
typeset -gi SF_PRESENT_LIVE=0 SF_PRESENT_WORK_ACTIVE=0
# Leading role chrome belongs to an entry rather than to a formatter of its own.
# ROLE is the role the entry opened, SECTION the number it took, and PRIOR the
# role in force beforehand, which retraction restores.
typeset -ga SF_PRESENT_ROLE=() SF_PRESENT_SECTION=() SF_PRESENT_PRIOR=()
typeset -g SF_PRESENT_LAST_ROLE=''
typeset -gi SF_PRESENT_SECTION_ID=0
typeset -g SF_PRESENT_ASSISTANT_INDEX=''

# Appends a formatter. Fails on a live tail, so a caller that forgets to settle
# a transition cannot grow a second mutable entry. REPLY is the new index.
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
  REPLY=${#SF_PRESENT_KIND}
  [[ $mode == final ]] || SF_PRESENT_LIVE=$REPLY
}

# Claims leading role chrome for an entry. A role already in force claims
# nothing, so only the first formatter of a run owns its rule.
sf_tui_formatter_role() {
  integer index=$1
  local role=$2
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  # Reclaiming would take a second section number and lose the role the first
  # claim displaced.
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

# Removes the live tail with any role chrome it owns, releasing its section
# number so numbering stays contiguous when a formatter had nothing visible.
sf_tui_formatter_retract() {
  integer index=${#SF_PRESENT_KIND}
  (( index && SF_PRESENT_LIVE == index )) || return 1
  if [[ -n $SF_PRESENT_ROLE[index] ]]; then
    [[ -z $SF_PRESENT_SECTION[index] ]] || (( --SF_PRESENT_SECTION_ID ))
    SF_PRESENT_LAST_ROLE=$SF_PRESENT_PRIOR[index]
  fi
  SF_PRESENT_LIVE=0
  sf_tui_formatter_keep 1 $(( index - 1 ))
}

# Drops a committed prefix. The live tail is never part of it.
sf_tui_formatter_drop() {
  integer count=$1 total=${#SF_PRESENT_KIND}
  (( count >= 0 && count <= total )) || return 1
  (( count )) || return 0
  (( ! SF_PRESENT_LIVE || SF_PRESENT_LIVE > count )) || return 1
  sf_tui_formatter_keep $(( count + 1 )) $total
  (( ! SF_PRESENT_LIVE )) || (( SF_PRESENT_LIVE -= count ))
}

# Applies one formatter-local commit to the head of the list. Committing every
# row drops the entry, otherwise it keeps the content and metadata its
# uncommitted suffix needs.
sf_tui_formatter_consume() {
  integer whole=$1 source=$2 leading=$3 body_rows=$4
  integer body_source committed_field spent_field
  local kind state continuation record trimmed segment
  (( ${#SF_PRESENT_KIND} )) || return 1
  if (( whole )); then
    sf_tui_formatter_drop 1
    return
  fi
  kind=$SF_PRESENT_KIND[1]
  [[ $kind == (message|reasoning|hook_model_context|hook_user_context|error|tool_call|tool_result) ]] ||
    return 1
  # A scan continuation measures the prefix the commit took, not what is left.
  record=$SF_PRESENT_TEXT[1]
  (( source >= 0 && source <= ${#record} )) || return 1
  (( ! source )) || SF_PRESENT_TEXT[1]=${record[source + 1,-1]}
  (( ! leading )) || {
    SF_PRESENT_ROLE[1]=''
    SF_PRESENT_SECTION[1]=''
    SF_PRESENT_PRIOR[1]=''
  }
  case $kind in
    message|reasoning)
      # Reset the frontier and spans with the prefix they covered, but carry the
      # state that prefix reached into the base: a resize rescans from zero.
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
      ;;
    hook_model_context|hook_user_context)
      # Complete records carry no scan cache, so only the state the committed
      # prefix reached survives into the suffix.
      if [[ $kind == hook_model_context ]]; then
        sf_tui_formatter_data 1 6 || return 1
        state=$REPLY
        sf_tui_formatter_data 1 7 || return 1
        continuation=$REPLY
        # Trimmed blank lines are consumed by the rows either side of the body,
        # so the prefix is measured against the trimmed body.
        sf_tui_format_trim "$record"
        trimmed=$REPLY
        body_source=$(( source - SF_FORMAT_TRIM_LEADING ))
        (( body_source <= ${#trimmed} )) || body_source=${#trimmed}
        if (( body_source > 0 )); then
          segment=${trimmed[1,body_source]}
          SF_PRESENT_HIGHLIGHT_SPANS=()
          sf_tui_markdown_highlight "$segment" 0 "$state" "${continuation:-0}"
          state=$REPLY
          continuation=0
          [[ $segment[-1] == $'\n' ]] || continuation=1
          sf_tui_formatter_set_field 1 6 "$state" || return 1
          sf_tui_formatter_set_field 1 7 "$continuation" || return 1
        fi
      fi
      (( ! leading )) || sf_tui_formatter_set_field 1 3 1 || return 1
      sf_tui_formatter_data 1 4 || return 1
      sf_tui_formatter_set_field 1 4 $(( REPLY + body_rows ))
      ;;
    error)
      (( ! leading )) || sf_tui_formatter_set_field 1 2 1
      ;;
    tool_call|tool_result)
      # A commit always takes the heading or rail with it, so what remains
      # continues under plain indentation.
      committed_field=6 spent_field=8
      [[ $kind == tool_result ]] || { committed_field=4; spent_field=5; }
      sf_tui_formatter_data 1 $spent_field || return 1
      sf_tui_formatter_set_field 1 $spent_field $(( REPLY + body_rows )) || return 1
      sf_tui_formatter_set_field 1 $committed_field 1
      ;;
  esac
}

# Private to this file's list operations. Every per-entry array belongs here or
# it drifts out of step with its kind.
sf_tui_formatter_keep() {
  integer first=$1 last=$2
  local name
  local -a values
  for name in SF_PRESENT_KIND SF_PRESENT_TEXT SF_PRESENT_DATA SF_PRESENT_ROLE \
      SF_PRESENT_SECTION SF_PRESENT_PRIOR; do
    values=( "${(@P)name}" )
    if (( last < first || first > ${#values} )); then
      set -A "$name"
    else
      set -A "$name" "${(@)values[first,last]}"
    fi
  done
}

# Discards retained presentation before a rebuild.
sf_tui_reset() {
  SF_PRESENT_LIVE=0
  SF_PRESENT_WORK_ACTIVE=0
  sf_tui_formatter_keep 1 0
  SF_PRESENT_LAST_ROLE=''
  SF_PRESENT_SECTION_ID=0
  SF_PRESENT_ASSISTANT_INDEX=''
}

# Per-type fields, set and read only by the formatter that owns the entry.
sf_tui_formatter_set_data() {
  integer index=$1
  shift
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  SF_PRESENT_DATA[index]=${(pj:\0:)@}
}

# Replaces one per-type field. Writing past the end grows the data with empty
# fields, which is how a formatter adds metadata it did not need at append.
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

# REPLY is field $2, counting from one, or empty when absent. Reading past the
# end is normal: formatters grow their data over time.
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

# Every normalized event presentation consumes. An unknown type is a protocol
# error and fails the caller. Tuples come from display-fields.jq and
# event-decode.jq padded to seven fields; the rest are synthesized by the
# controller.
#
#   activity_start                            activity_stop
#   system TEXT                               user TEXT
#   assistant_start                           assistant_end
#   assistant_message_delta INDEX TEXT
#   assistant_reasoning_delta INDEX TEXT [TOKENS]
#   assistant_reasoning_opaque INDEX          assistant_tool_call_delta INDEX
#   reasoning_tokens TOKENS
#   tool_call ID NAME CONTENT SUMMARY FORMAT
#   tool_result CALL_ID STATUS CONTENT FORMAT FULL SANDBOX_DENIAL
#     STATUS is an exit code, empty while pending, or "hidden" for no footer.
#   tool_permission                           tool_permission_clear
#   hook_activity HOOK SCRIPT TEXT            hook_activity
#     The no-argument form clears activity that ended without a result.
#   hook_result SCRIPT META MODEL_CONTEXT USER_CONTEXT
#   error HEADING DETAIL [end]
#     "end" closes the turn so the next record opens a new section.
sf_tui_event() {
  local type=$1 first=${2-} second=${3-} third=${4-}
  local fourth=${5-} fifth=${6-} sixth=${7-}
  integer index=${#SF_PRESENT_KIND}
  case $type in
    user)
      sf_tui_activity_retract || return 1
      sf_tui_message_append user "$first" || return 1
      ;;
    system)
      sf_tui_activity_retract || return 1
      sf_tui_message_append system "$first" || return 1
      ;;
    assistant_start)
      SF_PRESENT_ASSISTANT_INDEX=''
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
      sf_tui_activity_resume || return 1
      ;;
    activity_start)
      sf_tui_activity_start || return 1
      ;;
    activity_stop)
      sf_tui_activity_stop || return 1
      ;;
    hook_activity)
      sf_tui_hook_activity "$first" "$second" "$third" || return 1
      ;;
    hook_result)
      sf_tui_hook_result "$first" "$second" "$third" "$fourth" || return 1
      ;;
    error)
      if (( SF_PRESENT_LIVE == index && index > 0 )) &&
          [[ $SF_PRESENT_KIND[index] == tool_result ]]; then
        sf_tui_tool_abandon || return 1
      fi
      sf_tui_error_append "$first" "$second" || return 1
      ;;
    tool_call)
      sf_tui_tool_call "$first" "$second" "$third" "$fourth" "$fifth" || return 1
      ;;
    tool_result)
      sf_tui_tool_result "$first" "$second" "$third" "$fourth" "$fifth" "$sixth" ||
        return 1
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

# Settles the live assistant block, or retracts it when the stream produced
# nothing visible. Other live kinds have their own transitions.
sf_tui_assistant_close() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE )) || return 0
  (( SF_PRESENT_LIVE == index )) || return 1
  [[ $SF_PRESENT_KIND[index] == (message|reasoning) ]] || return 1
  if [[ $SF_PRESENT_TEXT[index] == *[!$'\n']* ]]; then
    sf_tui_formatter_settle
  else
    sf_tui_formatter_retract
  fi
}

# A source-index or visible-kind transition closes the prior block before its
# successor is appended. Opaque blocks cross the same boundary with no output.
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
