emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

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
  sf_tui_formatter_set_data $index "$id" "$name" before "$identity_start" \
    "$content" "$name" "$identity_start" || return 1
  sf_tui_formatter_role $index agent || return 1
}

# Hooks borrow a live tool block without changing its call identity or stage.
sf_tui_tool_view() {
  local command=$1 content=${2-} identity_start=${3:--1} script
  integer index=${#SF_PRESENT_KIND}
  sf_tui_formatter_pending tool || return 1
  sf_tui_safe "$content"
  SF_PRESENT_TEXT[index]=$REPLY
  script=${command:t}
  [[ $script != run ]] || script=${command:h:t}
  sf_tui_safe "$script"
  sf_tui_formatter_set_field $index 2 "$REPLY" || return 1
  sf_tui_formatter_set_field $index 4 "$identity_start"
}

sf_tui_tool_restore() {
  integer index=${#SF_PRESENT_KIND} field
  local -a original=()
  sf_tui_formatter_pending tool || return 1
  for field in 5 6 7; do
    sf_tui_formatter_data $index $field || return 1
    original+=( "$REPLY" )
  done
  sf_tui_tool_view "$original[2]" "$original[1]" "$original[3]"
}

sf_tui_tool_result() {
  local id=$1 content=${2-} name=${3-} identity_start=${4:--1} expected
  integer index=${#SF_PRESENT_KIND}
  if ! sf_tui_formatter_pending tool; then
    sf_tui_tool_call "$id" '' "$name" -1 || return 1
    index=${#SF_PRESENT_KIND}
  fi
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
  sf_tui_formatter_pending tool || return 0
  sf_tui_formatter_set_field ${#SF_PRESENT_KIND} 3 permission
}

sf_tui_tool_permission_clear() {
  integer index=${#SF_PRESENT_KIND}
  sf_tui_formatter_pending tool || return 0
  sf_tui_formatter_data $index 3 || return 1
  [[ $REPLY == permission ]] || return 0
  sf_tui_formatter_set_field $index 3 before
}

sf_tui_tool_abandon() {
  sf_tui_formatter_pending tool || return 0
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
