emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

# The presentation input boundary: the controller and transcript replay both
# deliver normalized events here, and the frozen runtime arrives through session
# updates. sf_tui_event is the only thing that may drive the formatter list
# below. It validates the event contract today; the content formatters bring
# the calls that build the list.

typeset -g SF_PRESENT_ERROR=''
# The frozen session runtime, established by transcript replay and refreshed by
# live session updates.
typeset -g SF_PRESENT_RUNTIME='null'
typeset -g SF_PRESENT_IDENTITY='' SF_PRESENT_FOOTER=''

# Presentation is one ordered list of formatters awaiting commitment. At most
# the tail is live; every earlier entry is final and can only be dropped once
# committed. KIND selects which formatter owns the entry, and TEXT is the
# logical content it has left to render — the substrate a successful commit
# consumes from.
# DATA is whatever the owning formatter needs beyond its text, NUL-joined and
# opaque here. Keeping it in one slot is what stops per-type fields becoming a
# second set of parallel arrays the store has to know about.
typeset -ga SF_PRESENT_KIND=() SF_PRESENT_TEXT=() SF_PRESENT_DATA=()
typeset -gi SF_PRESENT_LIVE=0
# Leading role chrome is not a formatter of its own. ROLE names the role an
# entry opened, SECTION the number that came with it, and PRIOR the role in
# force beforehand, which is what retraction restores. Holding PRIOR per entry
# is what lets the role survive dropping everything before it.
typeset -ga SF_PRESENT_ROLE=() SF_PRESENT_SECTION=() SF_PRESENT_PRIOR=()
typeset -g SF_PRESENT_LAST_ROLE=''
typeset -gi SF_PRESENT_SECTION_ID=0

# Appends a formatter. A live tail must be settled or retracted first, so a
# caller that forgets a transition fails here rather than silently growing a
# second mutable entry. REPLY is the new index.
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

# Claims leading role chrome for an entry. Entering a role already in force
# claims nothing, so only the first visible formatter of a run owns the rule.
sf_tui_formatter_role() {
  integer index=$1
  local role=$2
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  # Claiming twice would take a second section number and lose the role the
  # first claim displaced, drifting the numbering far from the cause.
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

# Removes the live tail along with any role chrome it owns. A retracted section
# releases its number so the next one reuses it, which is what keeps numbering
# contiguous when a formatter turns out to have no visible content.
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

# Private to this file's list operations. Every per-entry array belongs here,
# so a new field that skips this list silently drifts out of step with its kind.
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
  sf_tui_formatter_keep 1 0
  SF_PRESENT_LAST_ROLE=''
  SF_PRESENT_SECTION_ID=0
}

# Per-type fields, set and read only by the formatter that owns the entry.
sf_tui_formatter_set_data() {
  integer index=$1
  shift
  (( index > 0 && index <= ${#SF_PRESENT_KIND} )) || return 1
  SF_PRESENT_DATA[index]=${(pj:\0:)@}
}

# REPLY is field $2, counting from one, or empty when the entry has no such
# field. Reading past the end is normal: a formatter grows its data over time.
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

# The complete set of normalized events presentation consumes. An unknown type
# is a protocol error and must fail the caller. Tuples come from
# libexec/tui/display-fields.jq and event-decode.jq, padded to seven fields;
# the rest are synthesized by the controller.
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
  case $1 in
    user)
      sf_tui_message_append user "$2" || return 1
      ;;
    activity_start|activity_stop|system|assistant_start|assistant_end| \
    assistant_message_delta|assistant_reasoning_delta|assistant_reasoning_opaque| \
    assistant_tool_call_delta|reasoning_tokens|tool_call|tool_result| \
    tool_permission|tool_permission_clear|hook_activity|hook_result|error) ;;
    *) return 1 ;;
  esac
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
