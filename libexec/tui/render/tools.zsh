emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

sf_tui_tool_pending() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE == index && index > 0 )) &&
    [[ $SF_PRESENT_KIND[index] == tool ]]
}

sf_tui_tool_call() {
  local id=$1 content=${2-} name=${3-} identity_start=${4:--1}
  integer index
  sf_tui_hook_interrupt || return 1
  sf_tui_safe "$content"
  content=$REPLY
  sf_tui_safe "$name"
  name=$REPLY
  sf_tui_formatter_append tool live || return 1
  index=$REPLY
  SF_PRESENT_TEXT[index]=$content
  sf_tui_formatter_set_data $index "$id" "$name" before "$identity_start" || return 1
  sf_tui_formatter_role $index agent || return 1
}

sf_tui_tool_result() {
  local id=$1 content=${2-} name=${3-} identity_start=${4:--1} expected
  integer index=${#SF_PRESENT_KIND}
  sf_tui_tool_pending || return 1
  sf_tui_formatter_data $index 1 || return 1
  expected=$REPLY
  [[ $id == "$expected" ]] || return 1
  sf_tui_safe "$content"
  SF_PRESENT_TEXT[index]=$REPLY
  sf_tui_safe "$name"
  sf_tui_formatter_set_data $index "$id" "$REPLY" after "$identity_start" || return 1
  sf_tui_formatter_settle || return 1
  sf_tui_activity_resume
}

sf_tui_tool_permission() {
  sf_tui_tool_pending || return 0
  sf_tui_formatter_set_field ${#SF_PRESENT_KIND} 3 permission
}

sf_tui_tool_permission_clear() {
  integer index=${#SF_PRESENT_KIND}
  sf_tui_tool_pending || return 0
  sf_tui_formatter_data $index 3 || return 1
  [[ $REPLY == permission ]] || return 0
  sf_tui_formatter_set_field $index 3 before
}

sf_tui_tool_abandon() {
  sf_tui_tool_pending || return 0
  sf_tui_formatter_settle
}

sf_tui_format_tool() {
  integer index=$1 columns=$2 live identity_start spinner
  local body name stage

  sf_tui_format_start
  live=$(( SF_PRESENT_LIVE == index ))
  sf_tui_format_trim "$SF_PRESENT_TEXT[index]"
  body=$REPLY
  sf_tui_formatter_data $index 2 || return 1
  name=$REPLY
  sf_tui_formatter_data $index 3 || return 1
  stage=$REPLY
  sf_tui_formatter_data $index 4 || return 1
  identity_start=$REPLY
  spinner=$live
  [[ $stage != permission ]] || spinner=0
  sf_tui_format_execution $index $columns '⛭' tool "$name" $identity_start \
    $live $spinner "$body"
}
