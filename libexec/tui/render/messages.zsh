emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

sf_tui_user_message() {
  sf_tui_section user || return 1
  sf_tui_add message user '' "$1"
}

sf_tui_system_message() {
  sf_tui_section system || return 1
  sf_tui_add message system '' "$1"
}

sf_tui_assistant_block() {
  local source_index=$1
  integer index=${#SF_PRESENT_NODE_TYPE}

  if [[ $SF_PRESENT_ASSISTANT_INDEX != $source_index ]]; then
    if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_tui_close $index orphan_section || return 1
    fi
    SF_PRESENT_ASSISTANT_INDEX=$source_index
  fi
}

sf_tui_assistant_stream() {
  local type=$1 source_index=$2 text=${3-}
  integer index=${#SF_PRESENT_NODE_TYPE}
  sf_tui_assistant_block "$source_index" || return 1
  [[ -n $text ]] || return 0
  index=${#SF_PRESENT_NODE_TYPE}

  if (( ! index )) || [[ $SF_PRESENT_NODE_TYPE[index] != $type ||
      $SF_PRESENT_NODE_STATE[index] != open ]]; then
    if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_tui_close $index || return 1
    fi
    sf_tui_section agent || return 1
    sf_tui_add "$type" agent '' '' open || return 1
    index=$REPLY
  fi
  sf_tui_append $index "$text" || return 1
  REPLY=$index
}

sf_tui_assistant_start() {
  SF_PRESENT_ASSISTANT_INDEX=''
  sf_tui_section agent || return 1
  sf_tui_add activity agent '' '' open
}

sf_tui_assistant_text() {
  sf_tui_assistant_stream message "$1" "$2"
}

sf_tui_reasoning() {
  integer index
  sf_tui_assistant_stream reasoning "$1" "$2" || return 1
  if [[ -n ${3-} ]]; then
    index=${#SF_PRESENT_NODE_TYPE}
    [[ $index -gt 0 && $SF_PRESENT_NODE_TYPE[index] == reasoning &&
      $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
    SF_PRESENT_NODE_META[index]=$3
  fi
}

sf_tui_assistant_end() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  SF_PRESENT_ASSISTANT_INDEX=''
  (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]] || return 0
  [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
  sf_tui_close $index orphan_section
}
