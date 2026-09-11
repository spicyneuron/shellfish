emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

sf_tui_notice() {
  local severity=$1 heading=$2 body=${3-} state=${4:-closed}
  integer index=${#SF_PRESENT_NODE_TYPE} notice_index resume_tool=0
  if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
    if [[ $SF_PRESENT_NODE_TYPE[index] == notice ]]; then
      sf_tui_safe "$heading"; SF_PRESENT_NODE_HEADING[index]=$REPLY
      sf_tui_safe "$body"; SF_PRESENT_NODE_BODY[index]=$REPLY
      SF_PRESENT_NODE_ROLE[index]=$severity
      notice_index=$index
      [[ $state == open ]] || sf_tui_close $index || return 1
      (( ${#SF_PRESENT_NODE_TYPE} >= index )) || notice_index=0
      if [[ $state != open && -n $SF_PRESENT_TOOL_CURRENT ]]; then
        if [[ $severity == error ]]; then
          SF_PRESENT_TOOL_HEADING=()
          SF_PRESENT_TOOL_CONTENT=()
          SF_PRESENT_TOOL_SUMMARY=()
          SF_PRESENT_TOOL_FORMAT=()
          SF_PRESENT_TOOL_ORDER=()
          SF_PRESENT_TOOL_CURRENT=''
        else
          sf_tui_tool_open || return 1
        fi
      fi
      REPLY=$notice_index
      return 0
    fi
    if [[ $SF_PRESENT_NODE_TYPE[index] == tool_result ]]; then
      if [[ $severity == error ]]; then
        sf_tui_event tool_segment_close abandon || return 1
      else
        sf_tui_event tool_segment_close continue || return 1
        resume_tool=1
      fi
    else
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_tui_close $index orphan_section || return 1
    fi
  fi
  notice_index=0
  if [[ $state == open || $severity != notice || -n $body ]]; then
    sf_tui_add notice "$severity" "$heading" "$body" "$state" || return 1
    notice_index=$REPLY
  fi
  if (( resume_tool )) && [[ $state != open ]]; then
    sf_tui_tool_open || return 1
  fi
  REPLY=$notice_index
}

sf_tui_hook_activity() {
  local hook=${1-} text=${3-}
  if [[ -n $text ]]; then
    sf_tui_notice notice "$text" '' open || return 1
    (( ! REPLY )) || SF_PRESENT_NODE_META[REPLY]=$hook
  else
    sf_tui_notice notice '' '' closed
  fi
}

sf_tui_hook_model_context() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  if (( index )) && [[ $SF_PRESENT_NODE_TYPE[index] == notice &&
      $SF_PRESENT_NODE_ROLE[index] == notice && $SF_PRESENT_NODE_STATE[index] == open ]]; then
    SF_PRESENT_NODE_BODY[index]=''
    sf_tui_close $index || return 1
  fi
  sf_tui_add injection system "$1" "$3" || return 1
  SF_PRESENT_NODE_META[REPLY]=$2
}

sf_tui_hook_user_context() {
  sf_tui_notice notice "$1" "$3" closed || return 1
  (( ! REPLY )) || SF_PRESENT_NODE_META[REPLY]=$2
}

sf_tui_error() {
  sf_tui_notice error "$1" "${2-}" closed
}
