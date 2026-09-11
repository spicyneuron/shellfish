emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

# The presentation input boundary. Everything below is stable across the
# renderer replacement: the controller and transcript replay both deliver
# normalized events here, and the frozen runtime arrives through session
# updates. The ordered formatter list that consumes these events is being
# reimplemented; sf_tui_event validates its contract but renders nothing yet.

typeset -g SF_PRESENT_ERROR=''
# The frozen session runtime, established by transcript replay and refreshed by
# live session updates.
typeset -g SF_PRESENT_RUNTIME='null'
typeset -g SF_PRESENT_IDENTITY='' SF_PRESENT_FOOTER=''

# Discards retained presentation before a rebuild. The ordered formatter list it
# clears is being reimplemented, so there is nothing to drop yet.
sf_tui_reset() { : }

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
    activity_start|activity_stop|system|user|assistant_start|assistant_end| \
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
