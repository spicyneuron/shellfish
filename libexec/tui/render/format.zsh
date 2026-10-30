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

# RAIL styles the first cell of each row as the rail.
sf_tui_format_body() {
  integer limit=$1 row
  local style=${SF_PRESENT_STYLE[$2]-} rail=''
  local -a spans=()
  [[ -z ${3-} ]] || rail=${SF_PRESENT_STYLE[divider]-}
  for (( row = 1; row <= limit; row++ )); do
    spans=()
    [[ -z $style || -z $SF_WRAP_ROWS[row] ]] || spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]${rail:+ 0 1 $rail}" )
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
# Reasoning also holds its last line, so its rail can close there. FINAL takes
# the rest of the source and closes the block.
sf_tui_format_lines() {
  integer columns=$1 final=$2 shown=$SF_LIVE_SHOWN
  local text=$SF_LIVE_TEXT chunk head tail
  sf_tui_format_start
  if (( final )); then
    chunk=$text
  elif [[ $SF_LIVE_KIND == reasoning ]]; then
    tail=${text##*[!$'\n']}
    chunk=${text%"$tail"}
    [[ $chunk == *$'\n'* ]] || return 0
    chunk=${chunk%$'\n'*}
  else
    [[ $text == *$'\n'* ]] || return 0
    chunk=${text%$'\n'*}
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
  if [[ -n $chunk ]] || (( final )); then
    (( shown )) || sf_tui_format_opening $columns
    SF_LIVE_SHOWN=1
  fi
  [[ -z $chunk ]] || sf_tui_format_prose $columns "$chunk" || return 1
  (( final )) || return 0
  if [[ $SF_LIVE_KIND == reasoning ]]; then
    [[ -z $chunk ]] || SF_FORMAT_ROWS[-1]="╰${SF_FORMAT_ROWS[-1][2,-1]}"
  else
    sf_tui_format_summary $columns
  fi
}

# A block opens with its role rule; reasoning adds its heading.
sf_tui_format_opening() {
  integer columns=$1
  sf_tui_format_rule $columns "$SF_LIVE_ROLE" "$SF_LIVE_SECTION"
  [[ $SF_LIVE_KIND != reasoning ]] ||
    sf_tui_format_head $columns '✎ Reasoning' reasoning 2 11
}

# Message text is Markdown; streamed reasoning is plain text on the rail.
# System text spends one preview budget across the whole block.
sf_tui_format_prose() {
  integer columns=$1 limit spent=$SF_LIVE_SPENT
  local text=$2 prefix='' rail='' style=message preview=full
  (( ! SF_LIVE_HIDDEN )) || return 0
  SF_PRESENT_HIGHLIGHT_SPANS=()
  if [[ $SF_LIVE_KIND == reasoning ]]; then
    prefix='│ '
    rail=rail
    style=reasoning
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
  sf_tui_format_body $limit $style $rail
  SF_LIVE_SPENT=$(( spent + limit ))
}

# Clamped system text reports its size.
sf_tui_format_summary() {
  integer columns=$1
  (( SF_LIVE_HIDDEN )) || return 0
  sf_tui_token_count $SF_LIVE_TOTAL
  sf_tui_format_styled $columns "… ~$REPLY tokens" message clamp
}

# The status below an open block: its opening until text commits, then the
# spinner.
sf_tui_format_status() {
  integer columns=$1
  (( SF_LIVE_SHOWN )) || sf_tui_format_opening $columns
  sf_tui_spinner || return 0
  if [[ $SF_LIVE_KIND == message ]]; then
    sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" message '' activity
  else
    sf_tui_format_styled $columns "╰ $SF_PRESENT_ACTIVITY" reasoning '' activity
  fi
}

# Executions and notices ----------------------------------------------------

sf_tui_format_execution() {
  integer columns=$1 live=$(( ! $2 )) spinner=0 fold=0 diff=0
  integer row limit total heading hidden=0 span background cursor start end pass lead
  local body full head rest label badge='' suffix='' glyph preview text style kind=execution
  local base_style rail_style=${SF_PRESENT_STYLE[divider]-}
  local clamp=${SF_PRESENT_STYLE[clamp]-} badge_style='' glyph_style=''
  local strong=${SF_PRESENT_STYLE[syntax.strong]-}
  local -a projected=() spans=()

  sf_tui_format_start
  sf_tui_format_trim "$SF_LIVE_TEXT"
  body=$REPLY
  if [[ $SF_LIVE_KIND == reasoning ]]; then
    kind=reasoning
    glyph='✎'
    [[ -z $body ]] || body=$'\n'$body
    body="**Reasoning**$body"
    preview=$SF_PRESENT_PREVIEW_REASONING
  else
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
  fi
  base_style=${SF_PRESENT_STYLE[$kind]-}
  (( ! live )) || sf_tui_spinner && spinner=$live

  [[ $preview == full ]] || fold=1
  # A hunk header is the only reliable signal that output is a unified diff.
  [[ $body != (|*$'\n')'@@ -'*' @@'* ]] || diff=1
  head=${body%%$'\n'*}
  rest=${body:${#head}}
  # A leading **label** is the header's only markup. Later asterisks may come
  # from inserted input, such as a glob in a command.
  if [[ $head == '**'* ]]; then
    label=${${head#'**'}%%'**'*}
    if [[ -n $label && $head == "**$label**"* ]]; then
      head=$label${head#"**$label**"}
    else
      label=''
    fi
  fi
  [[ -z $SF_LIVE_FAILED || -z ${SF_PRESENT_STYLE[error]-} ]] ||
    glyph_style=${SF_PRESENT_STYLE[error]},bold
  if [[ -n $SF_LIVE_BYPASS ]]; then
    badge="[sandbox bypass $SF_LIVE_BYPASS]"
    case $SF_LIVE_BYPASS in
      requested) badge_style=${SF_PRESENT_STYLE[permission]-} ;;
      approved) badge_style=${SF_PRESENT_STYLE[muted]-} ;;
      *) badge_style=${SF_PRESENT_STYLE[error]-} ;;
    esac
    [[ -z $badge_style ]] || badge_style+=,bold
  fi

  sf_tui_format_rule $columns "$SF_LIVE_ROLE" "$SF_LIVE_SECTION"
  # The identity line always shows, however many rows it wraps to; the preview
  # budget covers the output below it. Settled clamped output adds its size to
  # the identity line and wraps again.
  for pass in 1 2; do
    full=${badge:+$badge }$head$suffix$rest
    SF_PRESENT_HIGHLIGHT_SPANS=()
    [[ -z $badge || -z $badge_style ]] ||
      SF_PRESENT_HIGHLIGHT_SPANS+=( 0 ${#badge} "$badge_style" )
    lead=$(( ${#badge} ? ${#badge} + 1 : 0 ))
    [[ -z $label || -z $strong ]] ||
      SF_PRESENT_HIGHLIGHT_SPANS+=( $lead $(( lead + ${#label} )) "$strong" )
    [[ -z $suffix || -z $clamp ]] ||
      SF_PRESENT_HIGHLIGHT_SPANS+=( $(( ${#full} - ${#rest} - ${#suffix} )) \
        $(( ${#full} - ${#rest} )) "$clamp" )
    (( ! diff )) || sf_tui_diff_highlight "$rest" $(( ${#full} - ${#rest} ))
    if (( fold )); then
      sf_tui_wrap $columns "${full[1,${#full}-${#rest}]}" '│ ' || return 1
      heading=${#SF_WRAP_ROWS}
      sf_tui_wrap -L $(( heading + preview + 1 )) $columns "$full" '│ ' \
        "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
    else
      sf_tui_wrap $columns "$full" '│ ' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
    fi
    total=${#SF_WRAP_ROWS}
    (( fold && total > heading + preview )) || break
    hidden=1
    (( ! live )) && [[ -z $suffix ]] || break
    sf_tui_token_count ${#rest} "$SF_LIVE_TOKENS"
    suffix=" · ~$REPLY tokens"
  done
  limit=$total
  (( ! hidden )) || limit=$(( heading + preview ))
  for (( row = 1; row <= limit; row++ )); do
    text=$SF_WRAP_ROWS[row]
    # The last output row closes the rail, or fades it when output is hidden.
    if (( row == 1 )); then
      text="$glyph${text[2,-1]}"
    elif (( hidden && row > heading && row == limit )); then
      text="┆${text[2,-1]}"
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
    if [[ -n $rail_style && $text == (│|╰|┆)* ]]; then
      spans+=( 0 1 "$rail_style" )
      cursor=1
    elif (( row == 1 )) && [[ -n $glyph_style ]]; then
      spans+=( 0 1 "$glyph_style" )
      cursor=1
    fi
    for (( span = 1; span <= ${#projected}; span += 3 )); do
      style=${projected[span + 2]}
      start=${projected[span]}
      end=${projected[span + 1]}
      # A background runs through the padding to the right margin.
      [[ $style != *bg=* ]] || end=${#text}
      (( start >= cursor )) || start=$cursor
      (( end <= ${#text} )) || end=${#text}
      (( start >= end )) && continue
      if [[ -n $base_style ]] && (( cursor < start )); then
        spans+=( $cursor $start "$base_style" )
      fi
      # zsh keeps the first fg, so a span with its own color stands alone.
      [[ -z $base_style || $style == *fg=* ]] || style="$base_style,$style"
      spans+=( $start $end "$style" )
      cursor=$end
    done
    if [[ -n $base_style ]] && (( cursor < ${#text} )); then
      spans+=( $cursor ${#text} "$base_style" )
    fi
    SF_FORMAT_ROWS+=( "$text" )
    SF_FORMAT_SPANS+=( "${(j: :)spans}" )
  done
  (( ! spinner )) ||
    sf_tui_format_styled $columns "╰ $SF_PRESENT_ACTIVITY" "$kind" '' activity
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
