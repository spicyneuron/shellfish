emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Formatters return rows, spans, source consumption, and a safe prefix.

typeset -ga SF_FORMAT_ROWS=() SF_FORMAT_SPANS=() SF_FORMAT_CONSUMED=()
typeset -gi SF_FORMAT_SAFE=0 SF_FORMAT_LEADING=0 SF_FORMAT_BODY_ROWS=0
# Trimmed characters remain logical source consumption.
typeset -gi SF_FORMAT_TRIM_LEADING=0 SF_FORMAT_TRIM_TRAILING=0
typeset -ga SF_FORMAT_SPAN=()
# Limit rows held for an incomplete inline construct.
typeset -gi SF_PRESENT_HOLD_ROWS=10

# Field 1 is the role, fields 2-9 hold shared Markdown state, and later fields
# are kind-specific. Blank final records do not claim a section.
sf_tui_message_append() {
  local role=$1 text=$2 mode=${3:-final}
  integer index
  REPLY=0
  [[ $mode != final || $text == *[!$'\n']* ]] || return 0
  sf_tui_safe "$text"
  text=$REPLY
  sf_tui_formatter_append message "$mode" || return 1
  index=$REPLY
  sf_tui_formatter_set_data $index "$role" 0 '' '' 0 0 0 '' 0 || return 1
  SF_PRESENT_TEXT[index]=$text
  sf_tui_formatter_role $index "$role" || return 1
  REPLY=$index
}

# Reasoning uses field 1 for exact tokens and fields 10-12 for total characters,
# spent preview rows, and expansion.
sf_tui_reasoning_append() {
  local mode=${1:-final}
  integer index expanded=1
  [[ $SF_PRESENT_PREVIEW_REASONING == 0 ]] && expanded=0
  sf_tui_formatter_append reasoning "$mode" || return 1
  index=$REPLY
  sf_tui_formatter_set_data $index '' 0 '' '' 0 0 0 '' 0 0 0 "$expanded" || return 1
  sf_tui_formatter_role $index agent || return 1
  REPLY=$index
}

sf_tui_reasoning_tokens() {
  sf_tui_formatter_set_field $1 1 "$2"
}

sf_tui_reasoning_grow() {
  integer index=$1 added=$2
  sf_tui_formatter_data $index 10 || return 1
  sf_tui_formatter_set_field $index 10 $(( REPLY + added ))
}

sf_tui_format_at_start() {
  (( SF_PRESENT_ROW_HEAD > ${#SF_PRESENT_ROW_TEXT} && ! SF_PRESENT_PREFIX_VISIBLE ))
}

# Role rules optionally end with a section number.
# Later highlight spans win, so style the section number last.
sf_tui_format_rule() {
  integer index=$1 columns=$2 title_start title_end number_start=-1
  local role=$SF_PRESENT_ROLE[index] number=$SF_PRESENT_SECTION[index] text
  sf_tui_format_at_start || sf_tui_format_blank
  [[ -n $role ]] || return 0
  SF_FORMAT_SPAN=()
  text="─ $role "
  title_end=${#text}
  if [[ -n $number ]] && (( ${#text} + ${#number} + 3 <= columns )); then
    text+=${(l:$(( columns - ${#text} - ${#number} - 3 ))::─:)""}
    text+=" $number ─"
    number_start=$(( ${#text} - ${#number} - 2 ))
  elif (( ${#text} < columns )); then
    text+=${(l:$(( columns - ${#text} ))::─:)""}
  fi
  (( ${#text} <= columns )) || text=${text[1,columns]}
  (( title_end <= ${#text} )) || title_end=${#text}
  title_start=$(( ${#text} < 2 ? ${#text} : 2 ))
  sf_tui_span 0 $title_start divider
  sf_tui_span $title_end ${#text} divider
  sf_tui_span $title_start $title_end "section.$role"
  (( number_start < 0 )) ||
    sf_tui_span $number_start $(( number_start + ${#number} )) muted
  SF_FORMAT_ROWS+=( "$text" )
  SF_FORMAT_SPANS+=( "${(j: :)SF_FORMAT_SPAN}" )
  SF_FORMAT_CONSUMED+=( 0 )
  sf_tui_format_blank
}

sf_tui_format_start() {
  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_CONSUMED=()
  SF_FORMAT_SAFE=0
  SF_FORMAT_LEADING=0
  SF_FORMAT_BODY_ROWS=0
  SF_FORMAT_TRIM_LEADING=0
  SF_FORMAT_TRIM_TRAILING=0
}

# Trim outer blank lines while recording their source length.
sf_tui_format_trim() {
  local head=${1%%[!$'\n']*} tail
  REPLY=${1#"$head"}
  tail=${REPLY##*[!$'\n']}
  REPLY=${REPLY%"$tail"}
  SF_FORMAT_TRIM_LEADING=${#head}
  SF_FORMAT_TRIM_TRAILING=${#tail}
}

sf_tui_span() {
  local style=${SF_PRESENT_STYLE[$3]:-$SF_PRESENT_STYLE[${3%%.*}]}
  integer start=$1 end=$2
  (( end > start )) && [[ -n $style ]] || return 0
  SF_FORMAT_SPAN+=( $start $end "$style" )
}

# Live messages expose only their stable wrapped prefix.
sf_tui_format_message() {
  integer index=$1 columns=$2 live stable visible chrome hidden=0
  local body=$SF_PRESENT_TEXT[index] role preview committed

  sf_tui_format_start

  sf_tui_formatter_data $index 1 || return 1
  role=$REPLY
  sf_tui_formatter_data $index 5 || return 1
  committed=$REPLY
  live=$(( SF_PRESENT_LIVE == index ))
  # Do not trim system text; retain one trailing newline for other live messages.
  if [[ $role != system ]]; then
    sf_tui_format_trim "$body"
    body=$REPLY
    if (( live && SF_FORMAT_TRIM_TRAILING )); then
      body+=$'\n'
      SF_FORMAT_TRIM_TRAILING=$(( SF_FORMAT_TRIM_TRAILING - 1 ))
    fi
  fi

  [[ $committed == 1 ]] || sf_tui_format_rule $index $columns
  chrome=${#SF_FORMAT_ROWS}
  SF_FORMAT_LEADING=$chrome

  if [[ -z $body ]]; then
    if (( live )); then
      sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" message || return 1
    else
      SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
    fi
    return 0
  fi

  SF_PRESENT_HIGHLIGHT_SPANS=()
  if (( live )); then
    sf_tui_markdown_cached $index "$body" $columns || return 1
  else
    sf_tui_markdown_highlight "$body"
  fi
  sf_tui_wrap $columns "$body" '' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  stable=${#SF_WRAP_ROWS}
  if (( live && stable )) && [[ $body != *$'\n' ]]; then
    stable=$(( stable - 1 ))
  fi
  visible=${#SF_WRAP_ROWS}
  preview=full
  [[ $role != system ]] || preview=$SF_PRESENT_PREVIEW_CONTEXT
  if [[ $preview != full ]] && (( visible > preview )); then
    visible=$preview
    hidden=1
  fi
  (( ! live )) || visible=$stable
  sf_tui_format_body $visible message
  sf_tui_format_edges $(( chrome + 1 )) ${#body}
  if [[ $role == system && $preview != full ]] && (( hidden )); then
    sf_tui_token_count ${#body}
    sf_tui_format_styled $columns "… ~$REPLY tokens" message clamp || return 1
  elif (( live )); then
    sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" message || return 1
  fi
  if (( ! live )); then
    SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
  elif (( stable )); then
    sf_tui_markdown_advance $index "$body" $chrome $stable $columns || return 1
    (( ! REPLY )) || SF_FORMAT_SAFE=$(( chrome + REPLY ))
  fi
}

# Only complete reasoning rows are safe while live.
sf_tui_format_reasoning() {
  integer index=$1 columns=$2 live stable visible chrome hidden=0 closed_line=0
  local body=$SF_PRESENT_TEXT[index] exact preview committed expanded total
  local tail tokens

  sf_tui_format_start
  live=$(( SF_PRESENT_LIVE == index ))
  [[ $body != *$'\n' ]] || closed_line=1
  sf_tui_format_trim "$body"
  body=$REPLY
  sf_tui_formatter_data $index 1 || return 1
  exact=$REPLY
  sf_tui_formatter_data $index 5 || return 1
  committed=$REPLY
  sf_tui_formatter_data $index 10 || return 1
  total=$REPLY
  sf_tui_formatter_data $index 11 || return 1
  sf_tui_format_preview "$SF_PRESENT_PREVIEW_REASONING" "$REPLY"
  preview=$REPLY
  sf_tui_formatter_data $index 12 || return 1
  expanded=$REPLY
  sf_tui_token_count "$total" "$exact"
  tokens=$REPLY

  [[ $committed == 1 ]] || sf_tui_format_rule $index $columns

  if [[ $expanded != 1 ]]; then
    if (( live )); then tail="✎ Thinking… $SF_PRESENT_ACTIVITY"
    else tail="✎ Thought for ~$tokens tokens."; fi
    sf_tui_format_styled $columns "$tail" reasoning clamp || return 1
    (( ! live )) && SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
    return 0
  fi

  if [[ $committed != 1 ]]; then
    sf_tui_format_styled $columns '✎ Reasoning' reasoning || return 1
  fi
  chrome=${#SF_FORMAT_ROWS}
  SF_FORMAT_LEADING=$chrome
  SF_PRESENT_HIGHLIGHT_SPANS=()
  if [[ -n $body ]]; then
    if (( live )); then
      sf_tui_markdown_cached $index "$body" $columns || return 1
    else
      sf_tui_markdown_highlight "$body"
    fi
  fi
  sf_tui_wrap $columns "$body" '  ' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  stable=${#SF_WRAP_ROWS}
  if (( live && stable && ! closed_line )); then
    stable=$(( stable - 1 ))
  fi
  visible=${#SF_WRAP_ROWS}
  if [[ $preview != full ]] && (( visible > preview )); then
    visible=$preview
    hidden=1
  fi
  sf_tui_format_body $visible reasoning
  sf_tui_format_edges $(( chrome + 1 )) ${#body}
  if (( live )); then
    if (( hidden )); then tail="  … ~$tokens tokens $SF_PRESENT_ACTIVITY"
    else tail="  $SF_PRESENT_ACTIVITY"; fi
  else
    if (( hidden )); then tail="  … Thought for ~$tokens tokens."
    else tail="  Thought for ~$tokens tokens."; fi
  fi
  sf_tui_format_styled $columns "$tail" reasoning clamp || return 1

  if (( ! live )); then
    SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
  elif (( stable )); then
    (( stable <= visible )) || stable=$visible
    sf_tui_markdown_advance $index "$body" $chrome $stable $columns || return 1
    (( ! REPLY )) || SF_FORMAT_SAFE=$(( chrome + REPLY ))
  fi
}

# Cached spans stay source-relative across wrapping and resize.
sf_tui_markdown_cached() {
  integer index=$1 columns=$3 frontier continuation=0
  local text=$2 state cached segment saved_continuation width
  local base_state base_continuation
  local -a carried fresh
  sf_tui_formatter_data $index 2 || return 1
  frontier=${REPLY:-0}
  sf_tui_formatter_data $index 3 || return 1
  state=$REPLY
  sf_tui_formatter_data $index 4 || return 1
  cached=$REPLY
  sf_tui_formatter_data $index 6 || return 1
  saved_continuation=$REPLY
  sf_tui_formatter_data $index 7 || return 1
  width=$REPLY
  sf_tui_formatter_data $index 8 || return 1
  base_state=$REPLY
  sf_tui_formatter_data $index 9 || return 1
  base_continuation=$REPLY
  if [[ $width != $columns ]]; then
    frontier=0
    state=$base_state
    cached=''
    saved_continuation=$base_continuation
  fi
  if [[ $frontier != <-> ]] || (( frontier > ${#text} )); then
    frontier=0
    state=''
    cached=''
  fi
  carried=( ${=cached} )
  SF_PRESENT_HIGHLIGHT_SPANS=()
  SF_PRESENT_HIGHLIGHT_INLINE_OPEN=0
  if (( frontier >= ${#text} )); then
    SF_PRESENT_HIGHLIGHT_SPANS=( "${(@)carried}" )
    return 0
  fi
  segment=${text[frontier + 1,-1]}
  if (( frontier )); then
    [[ $text[frontier] == $'\n' ]] || continuation=1
  else
    continuation=${saved_continuation:-0}
  fi
  sf_tui_markdown_highlight "$segment" $frontier "$state" $continuation
  fresh=( "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" )
  SF_PRESENT_HIGHLIGHT_SPANS=( "${(@)carried}" "${(@)fresh}" )
}

sf_tui_markdown_advance() {
  integer index=$1 chrome=$3 rows=$4 width=$5
  integer frontier target row continuation=0
  local text=$2 state cached segment next_state base_state base_continuation
  local -a scanned
  REPLY=0
  sf_tui_markdown_target $chrome $rows ${#text}
  target=$REPLY
  sf_tui_formatter_data $index 2 || return 1
  frontier=${REPLY:-0}
  if (( target == frontier )); then
    REPLY=$rows
    return 0
  fi
  sf_tui_formatter_data $index 3 || return 1
  state=$REPLY
  sf_tui_formatter_data $index 4 || return 1
  cached=$REPLY
  sf_tui_formatter_data $index 8 || return 1
  base_state=$REPLY
  sf_tui_formatter_data $index 9 || return 1
  base_continuation=$REPLY
  if (( target < frontier )); then
    frontier=0
    state=$base_state
    cached=''
    continuation=$base_continuation
  fi
  segment=${text[frontier + 1,target]}
  if (( frontier )); then
    [[ $text[frontier] == $'\n' ]] || continuation=1
  else
    continuation=$base_continuation
  fi
  SF_PRESENT_HIGHLIGHT_SPANS=()
  sf_tui_markdown_highlight "$segment" $frontier "$state" $continuation
  if (( SF_PRESENT_HIGHLIGHT_INLINE_OPEN )); then
    rows=$(( rows > SF_PRESENT_HOLD_ROWS ? rows - SF_PRESENT_HOLD_ROWS : 0 ))
    (( rows )) || { SF_PRESENT_HIGHLIGHT_SPANS=( ${=cached} ); return 0; }
    sf_tui_markdown_target $chrome $rows ${#text}
    target=$REPLY
    if (( target <= frontier )); then
      SF_PRESENT_HIGHLIGHT_SPANS=( ${=cached} )
      REPLY=$rows
      return 0
    fi
    segment=${text[frontier + 1,target]}
    SF_PRESENT_HIGHLIGHT_SPANS=()
    sf_tui_markdown_highlight "$segment" $frontier "$state" $continuation
  fi
  next_state=$REPLY
  continuation=0
  (( ! target )) || [[ $text[target] == $'\n' ]] || continuation=1
  scanned=( "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" )
  sf_tui_formatter_set_field $index 2 $target || return 1
  sf_tui_formatter_set_field $index 3 "$next_state" || return 1
  sf_tui_formatter_set_field $index 4 "$cached${cached:+ }${(j: :)scanned}" || return 1
  sf_tui_formatter_set_field $index 6 $continuation || return 1
  sf_tui_formatter_set_field $index 7 $width || return 1
  REPLY=$rows
}

sf_tui_markdown_target() {
  integer chrome=$1 rows=$2 length=$3 row target=0
  for (( row = 1; row <= rows; row++ )); do
    target=$(( target + SF_FORMAT_CONSUMED[chrome + row] ))
  done
  target=$(( target > SF_FORMAT_TRIM_LEADING ? target - SF_FORMAT_TRIM_LEADING : 0 ))
  REPLY=$(( target < length ? target : length ))
}

sf_tui_format_body() {
  integer limit=$1 row
  local style=${SF_PRESENT_STYLE[$2]-}
  local -a spans=()
  for (( row = 1; row <= limit; row++ )); do
    spans=()
    [[ -z $style || -z $SF_WRAP_ROWS[row] ]] || spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
    SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
  done
  SF_FORMAT_BODY_ROWS=$limit
}

# Chrome rows consume no source.
sf_tui_format_chrome() {
  integer columns=$1 row
  local text=$2 style=${SF_PRESENT_STYLE[$3]-}
  local -a spans=()
  shift 3
  sf_tui_wrap $columns "$text" '' "$@" || return 1
  for (( row = 1; row <= ${#SF_WRAP_ROWS}; row++ )); do
    spans=()
    [[ -z $style || -z $SF_WRAP_ROWS[row] ]] || spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
    SF_FORMAT_CONSUMED+=( 0 )
  done
}

sf_tui_format_styled() {
  integer columns=$1
  local text=$2 kind=$3 overlay=${SF_PRESENT_STYLE[${4-}]-}
  local rail=${SF_PRESENT_STYLE[divider]-}
  local -a source=()
  [[ -z $overlay ]] || source+=( 0 ${#text} "$overlay" )
  [[ -z $rail || $text != (│|╰)* ]] || source+=( 0 1 "$rail" )
  sf_tui_format_chrome $columns "$text" "$kind" "${(@)source}"
}

sf_tui_format_head() {
  integer columns=$1 value_start=$4 value_end=$5 clamp_start=${6:--1}
  local text=$2 kind=$3 style=${SF_PRESENT_STYLE[$3]-}
  local clamp=${SF_PRESENT_STYLE[clamp]-}
  local -a source=()
  [[ -z $style ]] || source+=( $value_start $value_end "$style,bold" )
  [[ -z $clamp ]] || (( clamp_start < 0 )) || source+=( $clamp_start ${#text} "$clamp" )
  sf_tui_format_chrome $columns "$text" "$kind" "${(@)source}"
}

sf_tui_format_preview() {
  local configured=$1
  integer spent=$2
  REPLY=$configured
  [[ $configured != full ]] || return 0
  REPLY=$(( configured > spent ? configured - spent : 0 ))
}

# Charge trimmed edges to the first and fully wrapped last body rows.
sf_tui_format_edges() {
  integer first=$1 length=$2 row consumed=0
  integer last=${#SF_FORMAT_CONSUMED}
  (( last >= first )) || return 0
  for (( row = first; row <= last; row++ )); do
    consumed=$(( consumed + SF_FORMAT_CONSUMED[row] ))
  done
  SF_FORMAT_CONSUMED[first]=$(( SF_FORMAT_CONSUMED[first] + SF_FORMAT_TRIM_LEADING ))
  (( consumed == length )) || return 0
  SF_FORMAT_CONSUMED[last]=$(( SF_FORMAT_CONSUMED[last] + SF_FORMAT_TRIM_TRAILING ))
}

sf_tui_format_blank() {
  SF_FORMAT_ROWS+=( '' )
  SF_FORMAT_SPANS+=( '' )
  SF_FORMAT_CONSUMED+=( 0 )
}
