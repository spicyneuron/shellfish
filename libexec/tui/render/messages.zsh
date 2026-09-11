emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Message formatters. Each renders one entry's uncommitted suffix at the current
# width and reports which of its rows are safe to commit.
#
# A formatter returns rows, per-row spans, per-row consumption, and a count of
# leading safe rows. Repaint concatenates those; nothing here writes to the
# terminal or knows what came before it beyond the role already in force.

typeset -ga SF_FORMAT_ROWS=() SF_FORMAT_SPANS=() SF_FORMAT_CONSUMED=()
typeset -gi SF_FORMAT_SAFE=0
# Scratch for one row's spans while a formatter builds them.
typeset -ga SF_FORMAT_SPAN=()
# At most this many stable rows wait for an incomplete inline construct. Older
# rows keep draining with best-effort styling instead of pinning a tall stream.
typeset -gi SF_PRESENT_HOLD_ROWS=10

# Data field 1 is the role. Live Markdown uses fields 2–4 for its scanned
# frontier, continuation state, and source spans.
#
# A complete record with nothing but blank lines is not presentation: it takes
# no entry, no role rule, and no section number, so numbering stays contiguous
# rather than leaving a gap where an invisible message sat. A live entry is
# still created, because its content has not arrived yet.
sf_tui_message_append() {
  local role=$1 text=$2 mode=${3:-final}
  integer index
  REPLY=0
  [[ $mode != final || $text == *[!$'\n']* ]] || return 0
  sf_tui_safe "$text"
  text=$REPLY
  sf_tui_formatter_append message "$mode" || return 1
  index=$REPLY
  sf_tui_formatter_set_data $index "$role" || return 1
  SF_PRESENT_TEXT[index]=$text
  sf_tui_formatter_role $index "$role" || return 1
  REPLY=$index
}

# Data field 1 is the exact token count when the provider reports one. Live
# Markdown uses the same cache fields as a message.
sf_tui_reasoning_append() {
  local mode=${1:-final}
  integer index
  sf_tui_formatter_append reasoning "$mode" || return 1
  index=$REPLY
  sf_tui_formatter_set_data $index '' || return 1
  sf_tui_formatter_role $index agent || return 1
  REPLY=$index
}

sf_tui_reasoning_tokens() {
  integer index=$1
  local exact=$2 frontier state spans
  sf_tui_formatter_data $index 2 || return 1
  frontier=$REPLY
  sf_tui_formatter_data $index 3 || return 1
  state=$REPLY
  sf_tui_formatter_data $index 4 || return 1
  spans=$REPLY
  sf_tui_formatter_set_data $index "$exact" "$frontier" "$state" "$spans"
}

# The rule a role opens: "─ role " padded out to the width, with the section
# number closing it when the role takes one. A number that cannot fit leaves a
# plain rule rather than a truncated one.
#
# Spans are emitted outermost first. The number sits inside the trailing rule,
# so its style has to come after the divider's to survive: region_highlight
# applies spans in order and the last one covering a character wins.
sf_tui_message_rule() {
  integer index=$1 columns=$2 title_start title_end number_start=-1
  local role=$SF_PRESENT_ROLE[index] number=$SF_PRESENT_SECTION[index] text
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
  # The rules either side of the title are one divider, so they share a style.
  sf_tui_span 0 $title_start divider
  sf_tui_span $title_end ${#text} divider
  sf_tui_span $title_start $title_end "section.$role"
  (( number_start < 0 )) ||
    sf_tui_span $number_start $(( number_start + ${#number} )) muted
  REPLY=$text
  SF_FORMAT_SPANS+=( "${(j: :)SF_FORMAT_SPAN}" )
}

# Appends one zero-based span to SF_FORMAT_SPAN when its style is configured,
# resolving "kind.role" before falling back to "kind".
sf_tui_span() {
  local style=${SF_PRESENT_STYLE[$3]:-$SF_PRESENT_STYLE[${3%%.*}]}
  integer start=$1 end=$2
  (( end > start )) && [[ -n $style ]] || return 0
  SF_FORMAT_SPAN+=( $start $end "$style" )
}

# Renders user, system, or assistant text. Complete records are wholly safe;
# live assistant text reports only its stable wrapped prefix.
sf_tui_format_message() {
  integer index=$1 columns=$2 row live stable visible chrome
  local body=$SF_PRESENT_TEXT[index] role style preview tail
  local -a spans=()

  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_CONSUMED=()
  SF_FORMAT_SAFE=0

  sf_tui_formatter_data $index 1 || return 1
  role=$REPLY
  live=$(( SF_PRESENT_LIVE == index ))
  # Leading blank lines are the previous turn's spacing, and a trailing run
  # collapses to nothing. System context keeps its source shape.
  if [[ $role != system ]]; then
    body=${body#"${body%%[!$'\n']*}"}
    tail=${body##*[!$'\n']}
    if (( live )) && [[ -n $tail ]]; then
      body=${body%"$tail"}$'\n'
    else
      body=${body%"$tail"}
    fi
  fi

  if [[ -n $SF_PRESENT_ROLE[index] ]]; then
    (( index == 1 && ! SF_PRESENT_PREFIX_VISIBLE )) || sf_tui_format_blank
    sf_tui_message_rule $index $columns
    SF_FORMAT_ROWS+=( "$REPLY" )
    SF_FORMAT_CONSUMED+=( 0 )
  fi
  sf_tui_format_blank
  chrome=${#SF_FORMAT_ROWS}

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
    sf_tui_markdown_cached $index "$body" || return 1
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
  if [[ $preview != full ]] && (( visible > preview )); then visible=$preview; fi
  (( ! live )) || visible=$stable
  style=${SF_PRESENT_STYLE[message]-}
  for (( row = 1; row <= visible; row++ )); do
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
    spans=()
    [[ -z $style || -z $SF_WRAP_ROWS[row] ]] ||
      spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
  done
  if [[ $role == system && $preview != full ]] && (( ${#SF_WRAP_ROWS} > preview )); then
    sf_tui_token_count "$body"
    sf_tui_format_styled $columns "… ~$REPLY tokens" message clamp || return 1
  elif (( live )); then
    sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" message || return 1
  fi
  if (( ! live )); then
    SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
  elif (( stable )); then
    sf_tui_markdown_advance $index "$body" $chrome $stable || return 1
    (( ! REPLY )) || SF_FORMAT_SAFE=$(( chrome + REPLY ))
  fi
}

# Reasoning displays its mutable final row but only reports complete wrapped
# rows as safe. Its summary and clamp remain unsafe until settlement.
sf_tui_format_reasoning() {
  integer index=$1 columns=$2 row live stable visible chrome hidden=0 closed_line=0
  local body=$SF_PRESENT_TEXT[index] exact preview=$SF_PRESENT_PREVIEW_REASONING
  local tail style tokens
  local -a spans=()

  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_CONSUMED=()
  SF_FORMAT_SAFE=0
  live=$(( SF_PRESENT_LIVE == index ))
  [[ $body != *$'\n' ]] || closed_line=1
  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}
  sf_tui_formatter_data $index 1 || return 1
  exact=$REPLY
  sf_tui_token_count "$body" "$exact"
  tokens=$REPLY

  if [[ -n $SF_PRESENT_ROLE[index] ]]; then
    (( index == 1 && ! SF_PRESENT_PREFIX_VISIBLE )) || sf_tui_format_blank
    sf_tui_message_rule $index $columns
    SF_FORMAT_ROWS+=( "$REPLY" )
    SF_FORMAT_CONSUMED+=( 0 )
  fi
  sf_tui_format_blank

  if [[ $preview == 0 ]]; then
    if (( live )); then tail="✎ Thinking… $SF_PRESENT_ACTIVITY"
    else tail="✎ Thought for ~$tokens tokens."; fi
    sf_tui_format_styled $columns "$tail" reasoning clamp || return 1
    (( ! live )) && SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
    return 0
  fi

  sf_tui_format_styled $columns '✎ Reasoning' reasoning || return 1
  chrome=${#SF_FORMAT_ROWS}
  SF_PRESENT_HIGHLIGHT_SPANS=()
  if [[ -n $body ]]; then
    if (( live )); then
      sf_tui_markdown_cached $index "$body" || return 1
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
  style=${SF_PRESENT_STYLE[reasoning]-}
  for (( row = 1; row <= visible; row++ )); do
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
    spans=()
    [[ -z $style || -z $SF_WRAP_ROWS[row] ]] || spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
  done
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
    sf_tui_markdown_advance $index "$body" $chrome $stable || return 1
    (( ! REPLY )) || SF_FORMAT_SAFE=$(( chrome + REPLY ))
  fi
}

# Scans only the suffix after this formatter's stable frontier. Cached spans
# remain source-relative, so wrapping and resize can project them afresh.
sf_tui_markdown_cached() {
  integer index=$1 frontier continuation=0
  local text=$2 state cached segment
  local -a carried fresh
  sf_tui_formatter_data $index 2 || return 1
  frontier=${REPLY:-0}
  sf_tui_formatter_data $index 3 || return 1
  state=$REPLY
  sf_tui_formatter_data $index 4 || return 1
  cached=$REPLY
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
  (( ! frontier )) || [[ $text[frontier] == $'\n' ]] || continuation=1
  sf_tui_markdown_highlight "$segment" $frontier "$state" $continuation
  fresh=( "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" )
  SF_PRESENT_HIGHLIGHT_SPANS=( "${(@)carried}" "${(@)fresh}" )
}

# Advances through stable body rows. An unresolved inline construct holds the
# last bounded row suffix; past that bound, its older rows use best-effort style.
sf_tui_markdown_advance() {
  integer index=$1 chrome=$3 rows=$4 frontier target=0 row continuation=0
  local text=$2 meta state cached segment next_state
  local -a scanned
  REPLY=0
  for (( row = 1; row <= rows; row++ )); do
    target=$(( target + SF_FORMAT_CONSUMED[chrome + row] ))
  done
  sf_tui_formatter_data $index 2 || return 1
  frontier=${REPLY:-0}
  if (( target <= frontier )); then
    REPLY=$rows
    return 0
  fi
  sf_tui_formatter_data $index 1 || return 1
  meta=$REPLY
  sf_tui_formatter_data $index 3 || return 1
  state=$REPLY
  sf_tui_formatter_data $index 4 || return 1
  cached=$REPLY
  segment=${text[frontier + 1,target]}
  (( ! frontier )) || [[ $text[frontier] == $'\n' ]] || continuation=1
  SF_PRESENT_HIGHLIGHT_SPANS=()
  sf_tui_markdown_highlight "$segment" $frontier "$state" $continuation
  if (( SF_PRESENT_HIGHLIGHT_INLINE_OPEN )); then
    rows=$(( rows > SF_PRESENT_HOLD_ROWS ? rows - SF_PRESENT_HOLD_ROWS : 0 ))
    (( rows )) || { SF_PRESENT_HIGHLIGHT_SPANS=( ${=cached} ); return 0; }
    target=0
    for (( row = 1; row <= rows; row++ )); do
      target=$(( target + SF_FORMAT_CONSUMED[chrome + row] ))
    done
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
  scanned=( "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" )
  sf_tui_formatter_set_data $index "$meta" "$target" "$next_state" \
    "$cached${cached:+ }${(j: :)scanned}" || return 1
  REPLY=$rows
}

sf_tui_format_styled() {
  integer columns=$1 row
  local text=$2 base=$3 overlay=${4-} base_style overlay_style
  base_style=${SF_PRESENT_STYLE[$base]-}
  [[ -z $overlay ]] || overlay_style=${SF_PRESENT_STYLE[$overlay]-}
  sf_tui_wrap $columns "$text" '' || return 1
  for (( row = 1; row <= ${#SF_WRAP_ROWS}; row++ )); do
    SF_FORMAT_SPAN=()
    [[ -z $base_style || -z $SF_WRAP_ROWS[row] ]] ||
      SF_FORMAT_SPAN+=( 0 ${#SF_WRAP_ROWS[row]} "$base_style" )
    [[ -z $overlay_style || -z $SF_WRAP_ROWS[row] ]] ||
      SF_FORMAT_SPAN+=( 0 ${#SF_WRAP_ROWS[row]} "$overlay_style" )
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_SPANS+=( "${(j: :)SF_FORMAT_SPAN}" )
    SF_FORMAT_CONSUMED+=( 0 )
  done
}

sf_tui_format_blank() {
  SF_FORMAT_ROWS+=( '' )
  SF_FORMAT_SPANS+=( '' )
  SF_FORMAT_CONSUMED+=( 0 )
}
