emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# A call is final when appended. Its following result stays live through
# permission and execution, and stores the one call ID presentation expects.

sf_tui_tool_pending() {
  integer index=${#SF_PRESENT_KIND}
  (( SF_PRESENT_LIVE == index && index > 0 )) &&
    [[ $SF_PRESENT_KIND[index] == tool_result ]]
}

sf_tui_tool_call() {
  local id=$1 name=$2 content=${3-} summary=${4-} format=${5:-json}
  integer index
  sf_tui_hook_interrupt || return 1
  sf_tui_safe "$name"
  name=$REPLY
  sf_tui_safe "$summary"
  summary=$REPLY
  sf_tui_safe "$content"
  content=$REPLY
  sf_tui_formatter_append tool_call || return 1
  index=$REPLY
  SF_PRESENT_TEXT[index]=$content
  sf_tui_formatter_set_data $index "$name" "$summary" "$format" || return 1
  sf_tui_formatter_role $index agent || return 1
  sf_tui_formatter_append tool_result live || return 1
  index=$REPLY
  sf_tui_formatter_set_data $index "$id" '' plain '' '' || return 1
}

sf_tui_tool_result() {
  local id=$1 code=${2-} content=${3-} format=${4:-plain}
  local full=${5-} sandbox=${6-} expected
  integer index=${#SF_PRESENT_KIND}
  sf_tui_tool_pending || return 1
  sf_tui_formatter_data $index 1 || return 1
  expected=$REPLY
  [[ $id == "$expected" ]] || return 1
  sf_tui_safe "$content"
  SF_PRESENT_TEXT[index]=$REPLY
  sf_tui_formatter_set_data $index "$id" "$code" "$format" "$full" "$sandbox" ||
    return 1
  sf_tui_formatter_settle || return 1
  sf_tui_activity_resume
}

sf_tui_tool_permission() {
  integer index=${#SF_PRESENT_KIND}
  sf_tui_tool_pending || return 0
  sf_tui_formatter_data $index 1 || return 1
  sf_tui_formatter_set_data $index "$REPLY" permission plain '' ''
}

sf_tui_tool_permission_clear() {
  local id
  integer index=${#SF_PRESENT_KIND}
  sf_tui_tool_pending || return 0
  sf_tui_formatter_data $index 2 || return 1
  [[ $REPLY == permission ]] || return 0
  sf_tui_formatter_data $index 1 || return 1
  id=$REPLY
  sf_tui_formatter_set_data $index "$id" '' plain '' ''
}

# A turn error closes a result where execution stopped. Normal cancellation
# supplies durable results before its error, so this is only the failure edge.
sf_tui_tool_abandon() {
  sf_tui_tool_pending || return 0
  sf_tui_formatter_settle
}

sf_tui_tool_notes() {
  local code=$1 sandbox=$2
  local -a notes=()
  [[ -z $code || $code == hidden || $code == permission ]] || notes+=( "exit $code" )
  [[ -z $sandbox ]] || notes+=( 'sandbox denial detected' )
  REPLY=${(j: · :)notes}
}

sf_tui_tool_highlight() {
  local body=$1 format=$2
  SF_PRESENT_HIGHLIGHT_SPANS=()
  case $format in
    plain) ;;
    file_diff) sf_tui_diff_highlight "$body" ;;
    markdown|md) sf_tui_markdown_highlight "$body" ;;
    *) sf_tui_code_highlight "$body" "$format" ;;
  esac
}

sf_tui_tool_pad() {
  local text=$1 character padded=$1
  integer columns=$2 width=0
  for character in ${(s::)text}; do
    sf_tui_cell_width "$character" $width
    (( width += REPLY ))
  done
  while (( width < columns )); do
    padded+=' '
    (( ++width ))
  done
  REPLY=$padded
}

# Appends wrapped syntax content. PREFIX supplies the two-column rail space;
# FIRST_RAIL replaces its first character only on the first output row.
sf_tui_format_tool_body() {
  integer columns=$1 row span has_background limit hidden=0
  local body=$2 prefix=$3 first_rail=$4 kind=$5 format=$6 text style
  local preview=${7:-full}
  local base_style=${SF_PRESENT_STYLE[$kind]-} rail_style=${SF_PRESENT_STYLE[divider]-}
  local -a projected=() spans=()

  sf_tui_tool_highlight "$body" "$format" || return 1
  sf_tui_wrap $columns "$body" "$prefix" "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  limit=${#SF_WRAP_ROWS}
  if [[ $preview != full ]] && (( limit > preview )); then
    limit=$preview
    hidden=1
  fi
  for (( row = 1; row <= limit; row++ )); do
    text=$SF_WRAP_ROWS[row]
    if (( row == 1 )) && [[ -n $first_rail ]]; then
      text="$first_rail${text[2,-1]}"
    fi
    projected=( ${=SF_WRAP_SPANS[row]} )
    has_background=0
    for (( span = 1; span <= ${#projected}; span += 3 )); do
      [[ ${projected[span + 2]} != *bg=* ]] || has_background=1
    done
    if (( has_background )); then
      sf_tui_tool_pad "$text" $columns
      text=$REPLY
    fi
    spans=()
    [[ -z $base_style || -z $text ]] || spans+=( 0 ${#text} "$base_style" )
    [[ -z $rail_style || $text != (│|╰)* ]] || spans+=( 0 1 "$rail_style" )
    for (( span = 1; span <= ${#projected}; span += 3 )); do
      style=${projected[span + 2]}
      if [[ $style == *bg=* ]]; then
        spans+=( 0 ${#text} "$style" )
      else
        spans+=( ${projected[span]} ${projected[span + 1]} "$style" )
      fi
    done
    SF_FORMAT_ROWS+=( "$text" )
    SF_FORMAT_SPANS+=( "${(j: :)spans}" )
    SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
  done
  REPLY=$hidden
}

sf_tui_format_tool_head() {
  integer columns=$1 name_end row
  local name=$2 summary=$3 text
  local base_style=${SF_PRESENT_STYLE[tool_call]-}
  local -a source=() spans=()
  text="⛭ $name${summary:+ · $summary}"
  name_end=$(( 2 + ${#name} ))
  [[ -z $base_style ]] || source=( 2 $name_end "$base_style,bold" )
  sf_tui_wrap $columns "$text" '' "${(@)source}" || return 1
  for (( row = 1; row <= ${#SF_WRAP_ROWS}; row++ )); do
    spans=()
    [[ -z $base_style || -z $SF_WRAP_ROWS[row] ]] ||
      spans+=( 0 ${#SF_WRAP_ROWS[row]} "$base_style" )
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
    SF_FORMAT_CONSUMED+=( 0 )
  done
}

sf_tui_format_tool_line() {
  integer columns=$1 row
  local text=$2 kind=$3 overlay=${4-}
  local base_style=${SF_PRESENT_STYLE[$kind]-}
  local rail_style=${SF_PRESENT_STYLE[divider]-} overlay_style=${SF_PRESENT_STYLE[$overlay]-}
  local -a source=() spans=()
  [[ -z $overlay_style ]] || source+=( 0 ${#text} "$overlay_style" )
  [[ -z $rail_style || $text != (│|╰)* ]] || source+=( 0 1 "$rail_style" )
  sf_tui_wrap $columns "$text" '' "${(@)source}" || return 1
  for (( row = 1; row <= ${#SF_WRAP_ROWS}; row++ )); do
    spans=()
    [[ -z $base_style || -z $SF_WRAP_ROWS[row] ]] ||
      spans+=( 0 ${#SF_WRAP_ROWS[row]} "$base_style" )
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
    SF_FORMAT_CONSUMED+=( 0 )
  done
}

sf_tui_format_tool() {
  integer index=$1 columns=$2 hidden=0 live
  local kind=$SF_PRESENT_KIND[index] body=$SF_PRESENT_TEXT[index]
  local first second format full sandbox preview notes tail overlay

  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_CONSUMED=()
  SF_FORMAT_SAFE=0
  live=$(( SF_PRESENT_LIVE == index ))
  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}

  sf_tui_formatter_data $index 1 || return 1
  first=$REPLY
  sf_tui_formatter_data $index 2 || return 1
  second=$REPLY
  sf_tui_formatter_data $index 3 || return 1
  format=$REPLY

  if [[ $kind == tool_call ]]; then
    if [[ -n $SF_PRESENT_ROLE[index] ]]; then
      (( index == 1 && ! SF_PRESENT_PREFIX_VISIBLE )) || sf_tui_format_blank
      sf_tui_message_rule $index $columns
      SF_FORMAT_ROWS+=( "$REPLY" )
      SF_FORMAT_CONSUMED+=( 0 )
      sf_tui_format_blank
    else
      (( index == 1 && ! SF_PRESENT_PREFIX_VISIBLE )) || sf_tui_format_blank
    fi
    sf_tui_format_tool_head $columns "$first" "$second" || return 1
    preview=$SF_PRESENT_PREVIEW_TOOL_CALL
    if [[ -n $body && $preview != 0 ]]; then
      sf_tui_format_tool_body $columns "$body" '│ ' '' tool_call "$format" "$preview" ||
        return 1
      hidden=$REPLY
      (( ! hidden )) || sf_tui_format_tool_line $columns '│ …' tool_call clamp || return 1
    fi
    SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
    return 0
  fi

  [[ $kind == tool_result ]] || return 1
  sf_tui_formatter_data $index 4 || return 1
  full=$REPLY
  sf_tui_formatter_data $index 5 || return 1
  sandbox=$REPLY
  preview=$SF_PRESENT_PREVIEW_TOOL_RESULT
  [[ $full != full ]] || preview=full

  if (( live )) && [[ $second == permission ]]; then
    return 0
  fi
  if [[ $preview == 0 ]]; then
    tail='╰'
    overlay=''
    if [[ -n $body ]]; then
      tail+=' …'
      overlay=clamp
    fi
    if (( live )); then
      tail+=" $SF_PRESENT_ACTIVITY"
    else
      sf_tui_tool_notes "$second" "$sandbox"
      [[ -z $REPLY ]] || tail+=" · $REPLY"
    fi
    sf_tui_format_tool_line $columns "$tail" tool_result "$overlay" || return 1
  elif [[ -n $body ]]; then
    sf_tui_format_tool_body $columns "$body" '  ' '╰' tool_result "$format" "$preview" ||
      return 1
    hidden=$REPLY
    sf_tui_tool_notes "$second" "$sandbox"
    notes=$REPLY
    if (( hidden )); then
      sf_tui_token_count "$body"
      tail="  … ~$REPLY tokens${notes:+ · $notes}"
      sf_tui_format_tool_line $columns "$tail" tool_result clamp || return 1
    elif [[ -n $notes ]]; then
      sf_tui_format_tool_line $columns "  $notes" tool_result || return 1
    fi
  elif (( live )); then
    sf_tui_format_tool_line $columns "╰ $SF_PRESENT_ACTIVITY" tool_result || return 1
  else
    sf_tui_tool_notes "$second" "$sandbox"
    tail="╰${REPLY:+ $REPLY}"
    sf_tui_format_tool_line $columns "$tail" tool_result || return 1
  fi
  (( live )) || SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}
