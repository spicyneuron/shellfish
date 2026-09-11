emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Hook output follows whatever content was live when the hook ran, so that
# formatter settles before the hook appends its own.
sf_tui_hook_interrupt() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]] || return 0
  case $SF_PRESENT_NODE_TYPE[index] in
    hook_activity)
      SF_PRESENT_NODE_HEADING[index]=''
      sf_tui_close $index
      ;;
    activity|message|reasoning)
      sf_tui_close $index orphan_section
      ;;
    *) return 1 ;;
  esac
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
  sf_tui_hook_interrupt
}

sf_tui_hook_result() {
  local script=$1 meta=$2 model=${3-} user=${4-}
  sf_tui_hook_interrupt || return 1
  if [[ -n $model ]]; then
    sf_tui_add hook_model_context system "$script" "$model" || return 1
    SF_PRESENT_NODE_META[REPLY]=$meta
  fi
  if [[ -n $user ]]; then
    sf_tui_add hook_user_context '' "$script" "$user" || return 1
    SF_PRESENT_NODE_META[REPLY]=$meta
  fi
}

# A turn error can arrive mid-tool, which ends that call where it stopped.
sf_tui_error() {
  sf_tui_tool_abandon || return 1
  sf_tui_hook_interrupt || return 1
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
    error) head="✕ $heading" ;;
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
  if (( formatter != 1 || SF_PRESENT_PREFIX_VISIBLE )); then
    text=$'\n'$text
    (( value_start++, value_stop++ ))
    (( clamp_start < 0 )) || (( clamp_start++, clamp_stop++ ))
  fi
  # Hook body rows are the whole indented content, so both spans cover it.
  if (( ! collapsed && ${#body} )); then
    content_start=$(( ${#text} - ${#body} ))
    content_end=${#text}
    body_start=$content_start
    body_end=$content_end
  fi
}
