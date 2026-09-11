emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Transient activity and complete hook or error output. These formatters own
# their spacing, wrapping, highlighting, previews, and safe-row decisions.

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

# A later label updates the same unsafe tail. Starting custom activity replaces
# standalone activity or closes the assistant content that preceded the hook.
sf_tui_hook_activity() {
  local text=${3-}
  integer index=${#SF_PRESENT_KIND}
  if [[ -z $text ]]; then
    (( SF_PRESENT_LIVE == index && index > 0 )) || return 0
    [[ $SF_PRESENT_KIND[index] == hook_activity ]] || return 0
    sf_tui_formatter_retract || return 1
    sf_tui_activity_resume
    return
  fi
  sf_tui_safe "$text"
  text=$REPLY
  if (( SF_PRESENT_LIVE == index && index > 0 )) &&
      [[ $SF_PRESENT_KIND[index] == hook_activity ]]; then
    SF_PRESENT_TEXT[index]=$text
    return
  fi
  sf_tui_hook_interrupt || return 1
  sf_tui_formatter_append hook_activity live || return 1
  index=$REPLY
  SF_PRESENT_TEXT[index]=$text
}

sf_tui_hook_interrupt() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE )) || return 0
  (( SF_PRESENT_LIVE == index )) || return 1
  case $SF_PRESENT_KIND[index] in
    activity|hook_activity) sf_tui_formatter_retract ;;
    message|reasoning) sf_tui_assistant_close ;;
    *) return 1 ;;
  esac
}

sf_tui_hook_result() {
  local script=$1 meta=$2 model=${3-} user=${4-}
  sf_tui_hook_interrupt || return 1
  [[ -z $model ]] || sf_tui_hook_append hook_model_context "$script" "$meta" "$model" ||
    return 1
  [[ -z $user ]] || sf_tui_hook_append hook_user_context "$script" "$meta" "$user" ||
    return 1
  sf_tui_activity_resume
}

sf_tui_hook_append() {
  local kind=$1 script=$2 meta=$3 text=$4
  integer index
  sf_tui_safe "$text"
  text=$REPLY
  sf_tui_formatter_append "$kind" || return 1
  index=$REPLY
  SF_PRESENT_TEXT[index]=$text
  sf_tui_formatter_set_data $index "$script" "$meta"
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
  # Errors close the current role without drawing a role rule of their own.
  SF_PRESENT_LAST_ROLE=error
}

sf_tui_format_hook_head() {
  integer columns=$1 value_start=$4 value_end=$5 clamp_start=${6:--1} row
  local text=$2 kind=$3 style=${SF_PRESENT_STYLE[$3]-}
  local clamp_style=${SF_PRESENT_STYLE[clamp]-}
  local -a source=() spans=()

  [[ -z $style ]] || source+=( $value_start $value_end "$style,bold" )
  [[ -z $clamp_style ]] || (( clamp_start < 0 )) ||
    source+=( $clamp_start ${#text} "$clamp_style" )
  sf_tui_wrap $columns "$text" '' "${(@)source}" || return 1
  for (( row = 1; row <= ${#SF_WRAP_ROWS}; row++ )); do
    spans=()
    [[ -z $style || -z $SF_WRAP_ROWS[row] ]] ||
      spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
    SF_FORMAT_CONSUMED+=( 0 )
  done
}

sf_tui_format_hook() {
  integer index=$1 columns=$2 row visible hidden=0
  local kind=$SF_PRESENT_KIND[index] body=$SF_PRESENT_TEXT[index]
  local first second head preview=full style clamp
  local -a spans=()

  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_CONSUMED=()
  SF_FORMAT_SAFE=0

  sf_tui_formatter_data $index 1 || return 1
  first=$REPLY
  sf_tui_formatter_data $index 2 || return 1
  second=$REPLY

  (( index == 1 && ! SF_PRESENT_PREFIX_VISIBLE )) || sf_tui_format_blank
  case $kind in
    activity)
      sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" activity || return 1
      return
      ;;
    hook_activity)
      sf_tui_format_hook_head $columns "$body" hook_activity 0 ${#body} || return 1
      sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" hook_activity || return 1
      return
      ;;
    hook_model_context)
      head="↪ $first${second:+ · $second}"
      preview=$SF_PRESENT_PREVIEW_CONTEXT
      ;;
    hook_user_context)
      head="ℹ $first${second:+ · $second}"
      preview=$SF_PRESENT_PREVIEW_CONTEXT
      ;;
    error)
      head="✕ $first"
      ;;
    *) return 1 ;;
  esac

  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}
  if [[ $preview == 0 && -n $body ]]; then
    sf_tui_token_count "$SF_PRESENT_TEXT[index]"
    clamp=" · ~$REPLY tokens"
    sf_tui_format_hook_head $columns "$head$clamp" "$kind" 2 \
      $(( 2 + ${#first} )) ${#head} || return 1
    body=''
  else
    sf_tui_format_hook_head $columns "$head" "$kind" 2 $(( 2 + ${#first} )) || return 1
  fi
  if [[ -n $body ]]; then
    SF_PRESENT_HIGHLIGHT_SPANS=()
    [[ $kind != hook_model_context ]] || sf_tui_markdown_highlight "$body"
    sf_tui_wrap $columns "$body" '  ' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
    visible=${#SF_WRAP_ROWS}
    if [[ $preview != full ]] && (( visible > preview )); then
      visible=$preview
      hidden=1
    fi
    style=${SF_PRESENT_STYLE[$kind]-}
    for (( row = 1; row <= visible; row++ )); do
      spans=()
      [[ -z $style || -z $SF_WRAP_ROWS[row] ]] ||
        spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
      SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
      SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
      SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
    done
    if (( hidden )); then
      sf_tui_token_count "$SF_PRESENT_TEXT[index]"
      clamp="  … ~$REPLY tokens"
      sf_tui_format_styled $columns "$clamp" "$kind" clamp || return 1
    fi
  fi
  SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}
