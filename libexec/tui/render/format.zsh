emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Formatting turns source into wrapped rows, styling spans, the source each row
# consumed, and the length of the prefix that can no longer change.

typeset -ga SF_FORMAT_ROWS=() SF_FORMAT_SPANS=() SF_FORMAT_CONSUMED=()
typeset -gi SF_FORMAT_SAFE=0 SF_FORMAT_LEADING=0 SF_FORMAT_BODY_ROWS=0
# Whether the preview budget held rows back from the block just formatted.
typeset -gi SF_FORMAT_PROSE_HIDDEN=0
# Trimmed characters remain logical source consumption.
typeset -gi SF_FORMAT_TRIM_LEADING=0 SF_FORMAT_TRIM_TRAILING=0
typeset -ga SF_FORMAT_SPAN=()
# Limit rows held for an incomplete inline construct.
typeset -gi SF_PRESENT_HOLD_ROWS=10

sf_tui_format_start() {
  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_CONSUMED=()
  SF_FORMAT_SAFE=0
  SF_FORMAT_LEADING=0
  SF_FORMAT_BODY_ROWS=0
  SF_FORMAT_PROSE_HIDDEN=0
  SF_FORMAT_TRIM_LEADING=0
  SF_FORMAT_TRIM_TRAILING=0
}

sf_tui_format_blank() {
  SF_FORMAT_ROWS+=( '' )
  SF_FORMAT_SPANS+=( '' )
  SF_FORMAT_CONSUMED+=( 0 )
}

sf_tui_format_at_start() {
  (( SF_PRESENT_ROW_HEAD > ${#SF_PRESENT_ROW_TEXT} && ! SF_PRESENT_PREFIX_VISIBLE ))
}

# Trim outer blank lines, but keep a live block's closing newline: it is how
# sf_tui_format_prose knows the last row is complete. The retained character
# comes out of the trailing count, so it stays charged to the row it belongs to.
sf_tui_format_trim_live() {
  integer live=$2
  sf_tui_format_trim "$1"
  (( live && SF_FORMAT_TRIM_TRAILING )) || return 0
  REPLY+=$'\n'
  SF_FORMAT_TRIM_TRAILING=$(( SF_FORMAT_TRIM_TRAILING - 1 ))
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

# Role rules optionally end with a section number.
# Later highlight spans win, so style the section number last.
sf_tui_format_rule() {
  integer columns=$1 title_start title_end number_start=-1
  local role=$2 number=${3-} text
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
  integer columns=$1 start
  local text=$2 kind=$3 overlay=${SF_PRESENT_STYLE[${4-}]-}
  local suffix=${SF_PRESENT_STYLE[${5-}]-} rail=${SF_PRESENT_STYLE[divider]-}
  local -a source=()
  [[ -z $overlay ]] || source+=( 0 ${#text} "$overlay" )
  if [[ -n $suffix && $text == *"$SF_PRESENT_ACTIVITY" ]]; then
    start=$(( ${#text} - ${#SF_PRESENT_ACTIVITY} ))
    source+=( $start ${#text} "$suffix" )
  fi
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

# Background styles must reach the right margin, so pad the row to full width.
sf_tui_format_fill() {
  local text=$1 character
  integer columns=$2 width=0
  for character in ${(s::)text}; do
    if [[ $character == [[:ascii:]] && $character != $'\t' ]]; then
      (( ++width ))
    else
      sf_tui_cell_width "$character" $width
      (( width += REPLY ))
    fi
  done
  repeat $(( columns > width ? columns - width : 0 )); do text+=' '; done
  REPLY=$text
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

# Messages ------------------------------------------------------------------

# Wrap and emit one prose body below the chrome already produced. Only complete
# rows are ever shown, so a live block never displays a row that can still grow.
# A MARKDOWN block settles no further than its scanner has resolved.
sf_tui_format_prose() {
  integer columns=$1 live=$2 markdown=$3 chrome total stable safe blank=0 closed=0
  local body=$4 prefix=$5 style=$6 preview=$7

  # Source that ends at a line boundary has no row left to grow.
  [[ $body != *$'\n' ]] || closed=1
  chrome=${#SF_FORMAT_ROWS}
  SF_FORMAT_LEADING=$chrome
  SF_PRESENT_HIGHLIGHT_SPANS=()
  if (( markdown )) && [[ -n $body ]]; then
    if (( live )); then
      sf_tui_markdown_cached "$body" $columns || return 1
    else
      sf_tui_markdown_highlight "$body"
    fi
  fi
  sf_tui_wrap $columns "$body" "$prefix" "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  total=${#SF_WRAP_ROWS}
  stable=$total
  (( ! live || ! stable || closed )) || stable=$(( stable - 1 ))
  if [[ $preview != full ]]; then
    # The budget spans the whole block, so rows already settled have spent it.
    preview=$(( preview > SF_LIVE_SPENT ? preview - SF_LIVE_SPENT : 0 ))
    (( total <= preview )) || SF_FORMAT_PROSE_HIDDEN=1
    (( stable <= preview )) || stable=$preview
  fi
  sf_tui_format_body $stable "$style"
  sf_tui_format_edges $(( chrome + 1 )) ${#body}
  (( live && stable )) || return 0
  safe=$stable
  if (( markdown && closed )); then
    # Keep one visible row live so a following blank line can cross terminal
    # handoffs as an internal row. ZLE collapses empty rows at either edge.
    safe=$(( safe - 1 ))
    [[ -n $SF_WRAP_ROWS[stable] ]] || blank=1
    while (( safe )) && [[ -z $SF_WRAP_ROWS[safe] ]]; do
      blank=1
      safe=$(( safe - 1 ))
    done
    (( ! blank || ! safe )) || safe=$(( safe - 1 ))
  fi
  (( safe )) || return 0
  if (( markdown )); then
    sf_tui_markdown_advance "$body" $chrome $safe $columns || return 1
    safe=$REPLY
  fi
  (( ! safe )) || SF_FORMAT_SAFE=$(( chrome + safe ))
}

# Message text is Markdown; only system text takes a preview budget.
sf_tui_format_message() {
  integer columns=$1 live=$(( ! $2 ))
  local body=$SF_LIVE_TEXT role=$SF_LIVE_ROLE preview=full

  sf_tui_format_start
  # System text is shown exactly as it was provided.
  if [[ $role != system ]]; then
    sf_tui_format_trim_live "$body" $live
    body=$REPLY
  fi

  (( SF_LIVE_CHROME )) || sf_tui_format_rule $columns "$role" "$SF_LIVE_SECTION"
  [[ $role != system ]] || preview=$SF_PRESENT_PREVIEW
  sf_tui_format_prose $columns $live 1 "$body" '' message "$preview" || return 1
  if [[ $role == system ]] && (( SF_FORMAT_PROSE_HIDDEN )); then
    sf_tui_token_count ${#body}
    sf_tui_format_styled $columns "… ~$REPLY tokens" message clamp || return 1
  elif (( live )) && sf_tui_spinner; then
    sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" message '' activity || return 1
  fi
  (( live )) || SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}

# Reasoning is plain text: no Markdown, no syntax highlighting.
sf_tui_format_reasoning() {
  integer columns=$1 live=$(( ! $2 ))
  local body=$SF_LIVE_TEXT tail tokens

  sf_tui_format_start
  sf_tui_format_trim_live "$body" $live
  body=$REPLY
  sf_tui_token_count $SF_LIVE_TOTAL "$SF_LIVE_TOKENS"
  tokens=$REPLY

  (( SF_LIVE_CHROME )) || sf_tui_format_rule $columns "$SF_LIVE_ROLE" "$SF_LIVE_SECTION"

  if [[ $SF_LIVE_EXPANDED != 1 ]]; then
    if (( live )); then tail="✎ Thinking… $SF_PRESENT_ACTIVITY"
    else tail="✎ Thought for ~$tokens tokens."; fi
    sf_tui_format_styled $columns "$tail" reasoning clamp activity || return 1
    (( live )) || SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
    return 0
  fi

  (( SF_LIVE_CHROME )) || sf_tui_format_styled $columns '✎ Reasoning' reasoning || return 1
  sf_tui_format_prose $columns $live 0 "$body" '  ' reasoning \
    "$SF_PRESENT_PREVIEW_REASONING" || return 1
  if (( live )); then
    if (( SF_FORMAT_PROSE_HIDDEN )); then tail="  … ~$tokens tokens $SF_PRESENT_ACTIVITY"
    else tail="  $SF_PRESENT_ACTIVITY"; fi
  else
    if (( SF_FORMAT_PROSE_HIDDEN )); then tail="  … Thought for ~$tokens tokens."
    else tail="  Thought for ~$tokens tokens."; fi
  fi
  sf_tui_format_styled $columns "$tail" reasoning clamp activity || return 1
  (( live )) || SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}

# Cached spans stay source-relative across wrapping and resize.
sf_tui_markdown_cached() {
  integer columns=$2 frontier=$SF_LIVE_FRONTIER continuation=0
  local text=$1 state=$SF_LIVE_STATE cached=$SF_LIVE_SPANS segment
  local -a carried fresh
  if [[ $SF_LIVE_WIDTH != $columns ]]; then
    frontier=0
    state=$SF_LIVE_BASE_STATE
    cached=''
    SF_LIVE_CONTINUATION=$SF_LIVE_BASE_CONTINUATION
  fi
  if (( frontier > ${#text} )); then
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
    continuation=$SF_LIVE_CONTINUATION
  fi
  sf_tui_markdown_highlight "$segment" $frontier "$state" $continuation
  fresh=( "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" )
  SF_PRESENT_HIGHLIGHT_SPANS=( "${(@)carried}" "${(@)fresh}" )
}

# Scan up to the source the safe rows consumed and keep that state for later.
sf_tui_markdown_advance() {
  integer chrome=$2 rows=$3 width=$4
  integer frontier=$SF_LIVE_FRONTIER target continuation=0
  local text=$1 state=$SF_LIVE_STATE cached=$SF_LIVE_SPANS segment next_state
  local -a scanned
  REPLY=0
  sf_tui_markdown_target $chrome $rows ${#text}
  target=$REPLY
  if (( target == frontier )); then
    REPLY=$rows
    return 0
  fi
  if (( target < frontier )); then
    frontier=0
    state=$SF_LIVE_BASE_STATE
    cached=''
    continuation=$SF_LIVE_BASE_CONTINUATION
  fi
  segment=${text[frontier + 1,target]}
  if (( frontier )); then
    [[ $text[frontier] == $'\n' ]] || continuation=1
  else
    continuation=$SF_LIVE_BASE_CONTINUATION
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
  SF_LIVE_FRONTIER=$target
  SF_LIVE_STATE=$next_state
  SF_LIVE_SPANS="$cached${cached:+ }${(j: :)scanned}"
  SF_LIVE_CONTINUATION=$continuation
  SF_LIVE_WIDTH=$width
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

# Executions and notices ----------------------------------------------------

sf_tui_format_execution() {
  integer columns=$1 live=$(( ! $2 )) spinner=0
  integer row limit chrome total hidden=0 span background cursor start end
  local body glyph preview text style kind=execution
  local base_style=${SF_PRESENT_STYLE[execution]-} rail_style=${SF_PRESENT_STYLE[divider]-}
  local -a projected=() spans=()

  sf_tui_format_start
  sf_tui_format_trim "$SF_LIVE_TEXT"
  body=$REPLY
  case $SF_LIVE_CLASS in
    tool) glyph='⛭' ;;
    context) glyph='↪' ;;
    *) glyph='ℹ' ;;
  esac
  preview=${SF_LIVE_PREVIEW:-default}
  if [[ $SF_PRESENT_PREVIEW == full ]]; then
    preview=full
  elif [[ $preview == default ]]; then
    preview=$SF_PRESENT_PREVIEW
  fi
  (( ! live )) || sf_tui_spinner && spinner=$live

  (( SF_LIVE_CHROME )) || sf_tui_format_rule $columns "$SF_LIVE_ROLE" "$SF_LIVE_SECTION"
  chrome=${#SF_FORMAT_ROWS}
  SF_PRESENT_HIGHLIGHT_SPANS=()
  # A hunk header is the only reliable signal that output is a unified diff.
  [[ $body != (|*$'\n')'@@ -'*' @@'* ]] || sf_tui_diff_highlight "$body"
  if (( ! live )) && [[ $preview != full ]]; then
    sf_tui_wrap -L $(( preview + 2 )) $columns "$body" '│ ' \
      "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  else
    sf_tui_wrap $columns "$body" '│ ' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  fi
  total=${#SF_WRAP_ROWS}
  limit=$total
  # The identity row always shows; the preview budget covers the output below it.
  if (( ! live )) && [[ $preview != full ]] && (( total > preview + 1 )); then
    limit=$(( preview + 1 ))
    hidden=1
  fi
  for (( row = 1; row <= limit; row++ )); do
    text=$SF_WRAP_ROWS[row]
    if (( row == 1 )); then
      text="$glyph${text[2,-1]}"
    elif (( ! live && ! hidden && row == limit )); then
      text="╰${text[2,-1]}"
    fi
    projected=( ${=SF_WRAP_SPANS[row]} )
    background=0
    for (( span = 1; span <= ${#projected}; span += 3 )); do
      [[ ${projected[span + 2]} != *bg=* ]] || background=1
    done
    if (( background )); then
      sf_tui_format_fill "$text" $columns
      text=$REPLY
    fi
    spans=()
    cursor=0
    if [[ -n $rail_style && $text == (│|╰)* ]]; then
      spans+=( 0 1 "$rail_style" )
      cursor=1
    fi
    for (( span = 1; span <= ${#projected}; span += 3 )); do
      style=${projected[span + 2]}
      if [[ $style == *bg=* ]]; then
        spans=( 0 ${#text} "$style" )
        cursor=${#text}
        break
      fi
      start=${projected[span]}
      end=${projected[span + 1]}
      (( start >= cursor )) || start=$cursor
      (( end <= ${#text} )) || end=${#text}
      (( start >= end )) && continue
      if [[ -n $base_style ]] && (( cursor < start )); then
        spans+=( $cursor $start "$base_style" )
      fi
      [[ -z $base_style ]] || style="$base_style,$style"
      spans+=( $start $end "$style" )
      cursor=$end
    done
    if [[ -n $base_style ]] && (( cursor < ${#text} )); then
      spans+=( $cursor ${#text} "$base_style" )
    fi
    SF_FORMAT_ROWS+=( "$text" )
    SF_FORMAT_SPANS+=( "${(j: :)spans}" )
    SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
  done
  if (( spinner )); then
    sf_tui_format_styled $columns "╰ $SF_PRESENT_ACTIVITY" "$kind" '' activity || return 1
  elif (( hidden )); then
    sf_tui_token_count ${#body}
    sf_tui_format_styled $columns "╰ … ~$REPLY tokens" "$kind" clamp || return 1
  elif (( ! live && limit <= 1 )); then
    sf_tui_format_styled $columns '╰' "$kind" || return 1
  fi
  SF_FORMAT_LEADING=$(( ${#SF_FORMAT_ROWS} > chrome ? chrome + 1 : chrome ))
  SF_FORMAT_BODY_ROWS=$limit
  (( live )) || SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}

# Notices settle immediately: a heading row followed by indented detail.
sf_tui_format_notice() {
  integer columns=$1 heading_length=$3
  local head=$2 body=$4

  sf_tui_format_start
  sf_tui_format_trim "$body"
  body=$REPLY
  sf_tui_format_at_start || sf_tui_format_blank
  sf_tui_format_head $columns "$head" error 2 $(( 2 + heading_length )) || return 1
  SF_FORMAT_LEADING=${#SF_FORMAT_ROWS}
  if [[ -n $body ]]; then
    SF_PRESENT_HIGHLIGHT_SPANS=()
    sf_tui_wrap $columns "$body" '  ' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
    sf_tui_format_body ${#SF_WRAP_ROWS} error
    sf_tui_format_edges $(( SF_FORMAT_LEADING + 1 )) ${#body}
  fi
  SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}
