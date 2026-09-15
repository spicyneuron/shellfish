emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# One mutable block covers every execution. A call opens it, hook activity may
# replace its contents repeatedly, permission changes its stage, and a result
# settles it. Data fields are id, name, stage, and display class.
sf_tui_execution_open() {
  local id=$1 name=$2 content=${3-} class=${4:-tool}
  integer index
  sf_tui_live_interrupt || return 1
  sf_tui_safe "$content"
  content=$REPLY
  sf_tui_safe "$name"
  name=$REPLY
  sf_tui_formatter_append execution live || return 1
  index=$REPLY
  SF_PRESENT_TEXT[index]=$content
  sf_tui_formatter_set_data $index "$id" "$name" before "$class" || return 1
  # A tool call belongs to the agent's turn; a hook notice stands on its own.
  [[ $class != tool ]] || sf_tui_formatter_role $index agent
}

# Activity borrows a live block, keeping the owning call's identity and stage.
# With nothing live it opens its own.
sf_tui_execution_call() {
  local id=$1 content=${2-} name=${3-} class=${4:-tool}
  integer index=${#SF_PRESENT_KIND}
  sf_tui_formatter_pending execution || {
    sf_tui_execution_open "$id" "$name" "$content" "$class"
    return
  }
  sf_tui_safe "$content"
  SF_PRESENT_TEXT[index]=$REPLY
  sf_tui_safe "$name"
  sf_tui_formatter_set_field $index 2 "$REPLY"
}

sf_tui_execution_settle() {
  local id=$1 content=${2-} name=${3-} class=${4:-tool}
  integer index=${#SF_PRESENT_KIND}
  # A result with nothing to show leaves no trace, live or settled.
  if [[ -z $content ]]; then
    if sf_tui_formatter_pending execution; then
      sf_tui_formatter_retract || return 1
    fi
    sf_tui_activity_resume
    return
  fi
  if ! sf_tui_formatter_pending execution; then
    sf_tui_execution_open "$id" "$name" '' "$class" || return 1
    index=${#SF_PRESENT_KIND}
  fi
  sf_tui_safe "$content"
  SF_PRESENT_TEXT[index]=$REPLY
  sf_tui_safe "$name"
  sf_tui_formatter_set_data $index "$id" "$REPLY" after "$class" || return 1
  sf_tui_formatter_settle || return 1
  sf_tui_activity_resume
}

sf_tui_execution_permission() {
  sf_tui_formatter_pending execution || return 0
  sf_tui_formatter_set_field ${#SF_PRESENT_KIND} 3 permission
}

sf_tui_execution_permission_clear() {
  integer index=${#SF_PRESENT_KIND}
  sf_tui_formatter_pending execution || return 0
  sf_tui_formatter_data $index 3 || return 1
  [[ $REPLY == permission ]] || return 0
  sf_tui_formatter_set_field $index 3 before
}

sf_tui_execution_abandon() {
  sf_tui_formatter_pending execution || return 0
  sf_tui_formatter_settle
}

sf_tui_format_execution_block() {
  integer index=$1 columns=$2 live spinner
  local body name stage class glyph preview

  sf_tui_format_start
  live=$(( SF_PRESENT_LIVE == index ))
  sf_tui_format_trim "$SF_PRESENT_TEXT[index]"
  body=$REPLY
  sf_tui_formatter_data $index 2 || return 1
  name=$REPLY
  sf_tui_formatter_data $index 3 || return 1
  stage=$REPLY
  sf_tui_formatter_data $index 4 || return 1
  class=$REPLY
  case $class in
    tool) glyph='⛭'; preview=full ;;
    context) glyph='↪'; preview=$SF_PRESENT_PREVIEW_CONTEXT ;;
    *) glyph='ℹ'; preview=full ;;
  esac
  spinner=$live
  [[ $stage != permission ]] || spinner=0
  sf_tui_format_execution $index $columns "$glyph" execution "$name" \
    $live $spinner "$body" "$preview"
}
