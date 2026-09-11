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
    sf_tui_add hook_activity '' "$text" '' open || return 1
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
    sf_tui_add hook_user_context '' "$script" "$user" || return 1
    SF_PRESENT_NODE_META[REPLY]=$meta
  fi
  (( ! resume )) || sf_tui_tool_open
}

sf_tui_error() {
  sf_tui_hook_interrupt abandon || return 1
  sf_tui_add error error "$1" "${2-}"
}

sf_tui_hook_preview_tail() {
  integer node=$1 hidden=$2
  local body=$SF_PRESENT_NODE_BODY[node]

  REPLY=''
  [[ $SF_PRESENT_NODE_TYPE[node] == hook_model_context ]] && (( hidden )) || return 0
  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}
  sf_tui_token_count "$body"
  REPLY="  … ~$REPLY tokens"
}

# Populate the active row walker's layout fields for one hook or error formatter.
sf_tui_hook_layout() {
  integer formatter=$1

  decorated=1
  previewed=1
  value_start=2
  case $type in
    hook_activity)
      # The running label carries no glyph of its own, so its title starts the row.
      head=$heading
      value_start=0
      activity=1
      withhold_all=1
      ;;
    hook_model_context)
      preview=$SF_PRESENT_PREVIEW_CONTEXT
      head="↪ $heading"
      ;;
    hook_user_context) head="ℹ $heading" ;;
    *) head="✕ $heading" ;;
  esac
  [[ -z $SF_PRESENT_NODE_META[formatter] ]] || head+=" · $SF_PRESENT_NODE_META[formatter]"
  value_stop=$(( value_start + ${#heading} ))
  leading=${body%%[!$'\n']*}
  source_base=${#leading}
  body=${body#"$leading"}
  body=${body%"${body##*[!$'\n']}"}
  text=$head
  if [[ $type == hook_model_context && $preview == 0 ]]; then
    collapsed=1
    if [[ -n $body ]]; then
      sf_tui_token_count "$body"
      text+=" · ~$REPLY tokens"
      clamp_start=$(( ${#head} + 1 ))
      clamp_stop=${#text}
    fi
  elif [[ -n $body ]]; then
    text+=$'\n'$body
  fi
  if (( ! collapsed && ${#body} )); then
    content_start=$(( ${#text} - ${#body} ))
    content_end=$(( content_start + ${#body} ))
  fi
  if (( formatter != 1 || SF_PRESENT_PREFIX_VISIBLE )); then
    text=$'\n'$text
    (( value_start < 0 )) || (( value_start++, value_stop++ ))
    (( clamp_start < 0 )) || (( clamp_start++, clamp_stop++ ))
    (( content_start < 0 )) || (( content_start++, content_end++ ))
  fi
  if (( ! collapsed && ${#body} )); then
    body_start=$(( ${#text} - ${#body} ))
    body_end=${#text}
  fi
}
