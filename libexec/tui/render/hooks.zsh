emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

sf_tui_activity_start() {
  SF_PRESENT_WORK_ACTIVE=1
  sf_tui_activity_resume
}

sf_tui_activity_resume() {
  (( SF_PRESENT_WORK_ACTIVE && ! SF_PRESENT_LIVE )) || return 0
  sf_tui_formatter_append activity live
}

sf_tui_activity_stop() {
  SF_PRESENT_WORK_ACTIVE=0
  sf_tui_activity_retract
}

sf_tui_activity_retract() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE )) || return 0
  (( SF_PRESENT_LIVE == index )) || return 1
  [[ $SF_PRESENT_KIND[index] == activity ]] || return 0
  sf_tui_formatter_retract
}

sf_tui_hook_interrupt() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE )) || return 0
  (( SF_PRESENT_LIVE == index )) || return 1
  case $SF_PRESENT_KIND[index] in
    activity) sf_tui_formatter_retract ;;
    message|reasoning) sf_tui_assistant_close ;;
    hook) sf_tui_formatter_settle ;;
    *) return 1 ;;
  esac
}

sf_tui_hook_append() {
  local fed_model=$1 hook=$2 script=$3 content=$4 identity_start=$5 live=${6-}
  integer index
  sf_tui_safe "$content"
  content=$REPLY
  sf_tui_formatter_append hook $live || return 1
  index=$REPLY
  SF_PRESENT_TEXT[index]=$content
  sf_tui_formatter_set_data $index "$hook" "$script" "$identity_start" "$fed_model"
}

# A running hook has produced no output yet, so it never carries model context.
sf_tui_hook_call() {
  if sf_tui_formatter_pending tool; then
    sf_tui_tool_view "$2" "${3-}" "${4:--1}" || return 1
    return
  fi
  if sf_tui_formatter_pending hook; then
    sf_tui_formatter_retract || return 1
  else
    sf_tui_hook_interrupt || return 1
  fi
  sf_tui_hook_append 0 "$1" "$2" "${3-}" "${4:--1}" live
}

# A silent script records no result, so a pending block may belong to an
# earlier one. Either way it is transient and gives way to this result.
sf_tui_hook_result() {
  local hook=$1 script=$2 content=${3-} identity_start=${4:--1} fed_model=${5:-0}
  if sf_tui_formatter_pending hook; then
    sf_tui_formatter_retract || return 1
  else
    sf_tui_hook_interrupt || return 1
  fi
  [[ -z $content ]] ||
    sf_tui_hook_append "$fed_model" "$hook" "$script" "$content" "$identity_start" ||
    return 1
  sf_tui_activity_resume
}

sf_tui_hook_abandon() {
  sf_tui_formatter_pending hook || return 0
  sf_tui_formatter_settle
}

sf_tui_error_append() {
  local heading=$1 detail=${2-}
  integer index
  SF_PRESENT_WORK_ACTIVE=0
  sf_tui_hook_interrupt || return 1
  sf_tui_safe "$heading"
  heading=$REPLY
  sf_tui_safe "$detail"
  detail=$REPLY
  sf_tui_formatter_append error || return 1
  index=$REPLY
  SF_PRESENT_TEXT[index]=$detail
  sf_tui_formatter_set_data $index "$heading"
  SF_PRESENT_LAST_ROLE=error
}

sf_tui_format_hook() {
  integer index=$1 columns=$2 live identity_start
  local kind=$SF_PRESENT_KIND[index] body=$SF_PRESENT_TEXT[index]
  local first head command script glyph preview

  sf_tui_format_start

  sf_tui_formatter_data $index 1 || return 1
  first=$REPLY
  case $kind in
    activity)
      sf_tui_format_at_start || sf_tui_format_blank
      sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" activity || return 1
      return
      ;;
    error)
      head="✕ $first"
      ;;
    hook)
      live=$(( SF_PRESENT_LIVE == index ))
      sf_tui_format_trim "$body"
      body=$REPLY
      sf_tui_formatter_data $index 2 || return 1
      command=$REPLY
      script=${command:t}
      [[ $script != run ]] || script=${command:h:t}
      sf_tui_safe "$script"
      script=$REPLY
      sf_tui_formatter_data $index 3 || return 1
      identity_start=$REPLY
      sf_tui_formatter_data $index 4 || return 1
      # Only a hook that fed the model is reference material worth previewing.
      if [[ $REPLY == 1 ]]; then
        glyph='↪'
        preview=$SF_PRESENT_PREVIEW_CONTEXT
      else
        glyph='ℹ'
        preview=full
      fi
      sf_tui_format_execution $index $columns "$glyph" hook "$script" \
        $identity_start $live $live "$body" "$preview"
      return
      ;;
    *) return 1 ;;
  esac

  sf_tui_format_trim "$body"
  body=$REPLY
  sf_tui_format_at_start || sf_tui_format_blank
  sf_tui_format_head $columns "$head" "$kind" 2 $(( 2 + ${#first} )) || return 1
  SF_FORMAT_LEADING=${#SF_FORMAT_ROWS}
  if [[ -n $body ]]; then
    SF_PRESENT_HIGHLIGHT_SPANS=()
    sf_tui_wrap $columns "$body" '  ' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
    sf_tui_format_body ${#SF_WRAP_ROWS} "$kind"
    sf_tui_format_edges $(( SF_FORMAT_LEADING + 1 )) ${#body}
  fi
  SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}
