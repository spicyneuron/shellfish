emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# One handler for live and loaded presentation actions. Workflow actions
# (session, permission, handoff) belong to the controller and never arrive here.
sf_tui_action() {
  local type=$1
  shift
  case $type in
    message_start) sf_tui_message_open "${1-}" ;;
    message_delta) sf_tui_message_stream "${1-}" "${2-}" "${3-}" "${4-}" ;;
    message_end) sf_tui_message_close ;;
    execution_update) sf_tui_execution_update "${1-}" "${2-}" "${3-}" "${4-}" "${5-}" ;;
    execution_end) sf_tui_execution_end "${1-}" "${2-}" "${3-}" "${4-}" "${5-}" ;;
    error) sf_tui_error_append "${1-}" "${2-}" ;;
    profile) sf_tui_identity "${1-}" ;;
    usage) sf_tui_usage "${1-}" "${2-}" ;;
    *) return 1 ;;
  esac
}

sf_tui_identity() {
  SF_PRESENT_IDENTITY=$1
  SF_PRESENT_FOOTER=$1
}

# Reported usage also refines the estimate a live reasoning summary shows.
sf_tui_usage() {
  local text=$1 reasoning=$2
  [[ -z $text ]] || SF_PRESENT_FOOTER="${SF_PRESENT_IDENTITY} · $text"
  [[ -z $reasoning ]] || sf_tui_reasoning_tokens "$reasoning"
}
