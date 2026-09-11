emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

sf_tui_hook_interrupt() {
  local mode=${1:-continue}
  integer index=${#SF_PRESENT_NODE_TYPE} resume=0
  if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
    case $SF_PRESENT_NODE_TYPE[index] in
      hook_activity)
        SF_PRESENT_NODE_HEADING[index]=''
        sf_tui_close $index || return 1
        [[ -z $SF_PRESENT_TOOL_CURRENT ]] || resume=1
        ;;
      tool_result)
        sf_tui_event tool_segment_close "$mode" || return 1
        [[ $mode != continue ]] || resume=1
        ;;
      activity|message|reasoning)
        sf_tui_close $index orphan_section || return 1
        ;;
      *) return 1 ;;
    esac
  fi
  if [[ $mode == abandon && -n $SF_PRESENT_TOOL_CURRENT ]]; then
    SF_PRESENT_TOOL_HEADING=()
    SF_PRESENT_TOOL_CONTENT=()
    SF_PRESENT_TOOL_SUMMARY=()
    SF_PRESENT_TOOL_FORMAT=()
    SF_PRESENT_TOOL_ORDER=()
    SF_PRESENT_TOOL_CURRENT=''
    resume=0
  fi
  REPLY=$resume
}

sf_tui_hook_activity() {
  local hook=${1-} text=${3-}
  integer index=${#SF_PRESENT_NODE_TYPE}
  if [[ -n $text ]]; then
    if (( index )) && [[ $SF_PRESENT_NODE_TYPE[index] == hook_activity &&
        $SF_PRESENT_NODE_STATE[index] == open ]]; then
      sf_tui_safe "$text"; SF_PRESENT_NODE_HEADING[index]=$REPLY
      SF_PRESENT_NODE_META[index]=$hook
      return
    fi
    sf_tui_hook_interrupt || return 1
    sf_tui_add hook_activity notice "$text" '' open || return 1
    SF_PRESENT_NODE_META[REPLY]=$hook
    return
  fi
  (( index )) && [[ $SF_PRESENT_NODE_TYPE[index] == hook_activity &&
    $SF_PRESENT_NODE_STATE[index] == open ]] || return 0
  sf_tui_hook_interrupt || return 1
  (( ! REPLY )) || sf_tui_tool_open
}

sf_tui_hook_result() {
  local script=$1 meta=$2 model=${3-} user=${4-}
  integer resume
  sf_tui_hook_interrupt || return 1
  resume=$REPLY
  if [[ -n $model ]]; then
    sf_tui_add hook_model_context system "$script" "$model" || return 1
    SF_PRESENT_NODE_META[REPLY]=$meta
  fi
  if [[ -n $user ]]; then
    sf_tui_add hook_user_context notice "$script" "$user" || return 1
    SF_PRESENT_NODE_META[REPLY]=$meta
  fi
  (( ! resume )) || sf_tui_tool_open
}

sf_tui_error() {
  sf_tui_hook_interrupt abandon || return 1
  sf_tui_add error error "$1" "${2-}"
}
