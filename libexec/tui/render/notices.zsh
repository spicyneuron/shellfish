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

sf_tui_live_interrupt() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE )) || return 0
  (( SF_PRESENT_LIVE == index )) || return 1
  case $SF_PRESENT_KIND[index] in
    activity) sf_tui_formatter_retract ;;
    message|reasoning) sf_tui_assistant_close ;;
    execution) sf_tui_formatter_settle ;;
    *) return 1 ;;
  esac
}

sf_tui_error_append() {
  local heading=$1 detail=${2-}
  integer index
  SF_PRESENT_WORK_ACTIVE=0
  sf_tui_live_interrupt || return 1
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

sf_tui_format_notice() {
  integer index=$1 columns=$2
  local kind=$SF_PRESENT_KIND[index] body=$SF_PRESENT_TEXT[index] first head

  sf_tui_format_start
  sf_tui_formatter_data $index 1 || return 1
  first=$REPLY
  case $kind in
    activity)
      sf_tui_format_at_start || sf_tui_format_blank
      sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" activity || return 1
      return
      ;;
    error) head="✕ $first" ;;
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
