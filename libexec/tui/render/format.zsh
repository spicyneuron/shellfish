emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Formatting turns source into wrapped rows and styling spans. LEADING counts
# the role chrome before the content those rows introduce.

typeset -ga SF_FORMAT_ROWS=() SF_FORMAT_SPANS=()
typeset -gi SF_FORMAT_LEADING=0
typeset -ga SF_FORMAT_SPAN=()

sf_tui_format_start() {
  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_LEADING=0
}

sf_tui_format_blank() {
  SF_FORMAT_ROWS+=( '' )
  SF_FORMAT_SPANS+=( '' )
}

# Trim outer blank lines.
sf_tui_format_trim() {
  local head=${1%%[!$'\n']*} tail
  REPLY=${1#"$head"}
  tail=${REPLY##*[!$'\n']}
  REPLY=${REPLY%"$tail"}
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
  sf_tui_format_blank
  SF_FORMAT_LEADING=${#SF_FORMAT_ROWS}
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
  done
}

sf_tui_format_chrome() {
  integer columns=$1
  local text=$2 kind=$3
  shift 3
  sf_tui_wrap $columns "$text" '' "$@" || return 1
  sf_tui_format_body ${#SF_WRAP_ROWS} "$kind"
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

# Messages ------------------------------------------------------------------

# Format the complete lines of the open message or reasoning block. Trailing
# blank lines wait for the text after them, so a block never ends on one.
# FINAL takes the rest of the source and adds the block's summary.
sf_tui_format_lines() {
  integer columns=$1 final=$2 shown=$SF_LIVE_SHOWN
  local text=$SF_LIVE_TEXT chunk head tail
  sf_tui_format_start
  if (( ! final )); then
    [[ $text == *$'\n'* && $SF_LIVE_EXPANDED == 1 ]] || return 0
    chunk=${text%$'\n'*}
  else
    chunk=$text
  fi
  tail=${chunk##*[!$'\n']}
  chunk=${chunk%"$tail"}
  SF_LIVE_TEXT=${text[${#chunk} + 1,-1]}
  # Leading blank lines are trimmed; later, a newline ends the line before it.
  if (( shown )); then
    chunk=${chunk#$'\n'}
  else
    head=${chunk%%[!$'\n']*}
    chunk=${chunk#"$head"}
  fi
  # Collapsed reasoning shows only its summary.
  (( SF_LIVE_EXPANDED )) || chunk=''
  if [[ -n $chunk ]] || (( final )); then
    (( shown )) || sf_tui_format_rule $columns "$SF_LIVE_ROLE" "$SF_LIVE_SECTION"
    SF_LIVE_SHOWN=1
  fi
  [[ -z $chunk ]] || sf_tui_format_prose $columns "$chunk" || return 1
  (( ! final )) || sf_tui_format_summary $columns
}

# Message text is Markdown; reasoning is plain text under its icon. System
# text and reasoning spend one preview budget across the whole block.
sf_tui_format_prose() {
  integer columns=$1 limit first=$(( ${#SF_FORMAT_ROWS} + 1 )) spent=$SF_LIVE_SPENT
  local text=$2 prefix='' style=message preview=full
  (( ! SF_LIVE_HIDDEN )) || return 0
  SF_PRESENT_HIGHLIGHT_SPANS=()
  if [[ $SF_LIVE_KIND == reasoning ]]; then
    prefix='  '
    style=reasoning
    preview=$SF_PRESENT_PREVIEW_REASONING
  else
    [[ $SF_LIVE_ROLE != system ]] || preview=$SF_PRESENT_PREVIEW
    sf_tui_markdown_highlight "$text" "$SF_LIVE_STATE"
    SF_LIVE_STATE=$REPLY
  fi
  sf_tui_wrap $columns "$text" "$prefix" "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  limit=${#SF_WRAP_ROWS}
  if [[ $preview != full ]] && (( limit > preview - spent )); then
    limit=$(( preview > spent ? preview - spent : 0 ))
    SF_LIVE_HIDDEN=1
  fi
  sf_tui_format_body $limit $style
  SF_LIVE_SPENT=$(( spent + limit ))
  if [[ $SF_LIVE_KIND == reasoning ]] && (( ! spent && limit )); then
    SF_FORMAT_ROWS[first]="✎ ${SF_FORMAT_ROWS[first][3,-1]}"
  fi
}

sf_tui_format_summary() {
  integer columns=$1
  local text
  if [[ $SF_LIVE_KIND == reasoning ]]; then
    sf_tui_token_count $SF_LIVE_TOTAL "$SF_LIVE_TOKENS"
    if (( ! SF_LIVE_EXPANDED )); then text="✎ Thought for ~$REPLY tokens."
    elif (( SF_LIVE_HIDDEN )); then text="  … Thought for ~$REPLY tokens."
    else text="  Thought for ~$REPLY tokens."; fi
    sf_tui_format_styled $columns "$text" reasoning clamp
  elif (( SF_LIVE_HIDDEN )); then
    sf_tui_token_count $SF_LIVE_TOTAL
    sf_tui_format_styled $columns "… ~$REPLY tokens" message clamp
  fi
}

# The status below an open block: its rule until text commits, then the
# spinner, and for reasoning what the preview hides.
sf_tui_format_status() {
  integer columns=$1
  local text spinner=''
  (( SF_LIVE_SHOWN )) || sf_tui_format_rule $columns "$SF_LIVE_ROLE" "$SF_LIVE_SECTION"
  ! sf_tui_spinner || spinner=$SF_PRESENT_ACTIVITY
  if [[ $SF_LIVE_KIND == message ]]; then
    [[ -z $spinner ]] || sf_tui_format_styled $columns "$spinner" message '' activity
    return
  fi
  # Under the reasoning indent, the spinner alone needs no text before it.
  text=' '
  if (( ! SF_LIVE_EXPANDED )); then
    text="✎ Thinking…"
  elif [[ $SF_PRESENT_PREVIEW_REASONING != full ]] &&
      (( SF_LIVE_SPENT >= SF_PRESENT_PREVIEW_REASONING )); then
    sf_tui_token_count $SF_LIVE_TOTAL "$SF_LIVE_TOKENS"
    text="  … ~$REPLY tokens"
  fi
  [[ -z $spinner ]] || text+=" $spinner"
  [[ $text != ' ' ]] || return 0
  sf_tui_format_styled $columns "$text" reasoning clamp activity
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

  sf_tui_format_rule $columns "$SF_LIVE_ROLE" "$SF_LIVE_SECTION"
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
  done
  if (( spinner )); then
    sf_tui_format_styled $columns "╰ $SF_PRESENT_ACTIVITY" "$kind" '' activity || return 1
  elif (( hidden )); then
    sf_tui_token_count ${#body}
    sf_tui_format_styled $columns "╰ … ~$REPLY tokens" "$kind" clamp || return 1
  elif (( ! live && limit <= 1 )); then
    sf_tui_format_styled $columns '╰' "$kind" || return 1
  fi
}

# Notices settle immediately: a heading row followed by indented detail.
sf_tui_format_notice() {
  integer columns=$1 heading_length=$3
  local head=$2 body=$4

  sf_tui_format_start
  sf_tui_format_trim "$body"
  body=$REPLY
  sf_tui_format_head $columns "$head" error 2 $(( 2 + heading_length )) || return 1
  if [[ -n $body ]]; then
    sf_tui_wrap $columns "$body" '  ' || return 1
    sf_tui_format_body ${#SF_WRAP_ROWS} error
  fi
}
