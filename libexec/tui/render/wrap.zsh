emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Span offsets are characters; cells only determine row breaks.

typeset -ga SF_TUI_WRAP_ROWS=() SF_TUI_WRAP_SPANS=()

# Spans are ordered, zero-based, half-open ranges over TEXT.
sf_tui_wrap() {
  # Rejecting a call never exposes prior output.
  SF_TUI_WRAP_ROWS=()
  SF_TUI_WRAP_SPANS=()
  integer limit=0
  if [[ ${1-} == -L ]]; then
    (( $# >= 5 )) || return 1
    limit=$2
    (( limit > 0 )) || return 1
    shift 2
  fi
  (( $# >= 3 )) || return 1
  integer columns=$1
  local text=$2 prefix=$3
  shift 3
  local -a spans=( "$@" )
  (( ${#spans} % 3 == 0 && columns > 0 )) || return 1
  local character line
  integer index total width column break_display break_source
  integer prefix_width prefix_length row_start span_head=1 base=1 newline
  # Track each display character's source index; prefix characters use zero.
  local -a display=() source=()

  total=${#text}
  prefix_length=${#prefix}
  prefix_width=0
  for character in ${(s::)prefix}; do
    sf_tui_cell_width "$character" $prefix_width
    prefix_width=$(( prefix_width + REPLY ))
  done
  (( prefix_width < columns )) || return 1

  # Each logical line wraps alone. A newline ends its row even when empty.
  for line in "${(@ps:\n:)text}"; do
    newline=$(( base + ${#line} <= total ))
    if [[ $line == *[^[:ascii:]]* || $line == *$'\t'* ]]; then
      sf_tui_wrap_cells || return 0
    else
      sf_tui_wrap_ascii || return 0
    fi
    base=$(( base + ${#line} + 1 ))
  done
}

# Every character of LINE takes one cell, so rows are slices of it.
sf_tui_wrap_ascii() {
  integer first=1 next cut after room=$(( columns - prefix_width ))
  local inner
  while (( ${#line} - first + 1 > room )); do
    next=$(( first + room ))
    cut=$(( next - 1 ))
    after=$next
    inner=${line[first + 1,next - 1]}
    if [[ $line[next] == ' ' ]]; then
      after=$(( next + 1 ))
    elif [[ $inner == *' '* ]]; then
      # Break at the last space after the row's first character.
      inner=${inner% *}
      cut=$(( first + ${#inner} ))
      after=$(( cut + 2 ))
    fi
    sf_tui_wrap_slice $first $cut
    (( ! limit || ${#SF_TUI_WRAP_ROWS} < limit )) || return 1
    first=$after
  done
  (( newline || first <= ${#line} )) || return 0
  sf_tui_wrap_slice $first ${#line}
  (( ! limit || ${#SF_TUI_WRAP_ROWS} < limit ))
}

# Emits LINE characters FIRST through LAST, projecting spans arithmetically.
sf_tui_wrap_slice() {
  integer first=$(( base + $1 - 1 )) last=$(( base + $2 - 1 )) span low high
  local -a projected=()
  SF_TUI_WRAP_ROWS+=( "$prefix$line[$1,$2]" )
  if (( last >= first )); then
    while (( span_head <= ${#spans} && spans[span_head + 1] < first )); do
      (( span_head += 3 ))
    done
    for (( span = span_head; span <= ${#spans}; span += 3 )); do
      (( spans[span] < last )) || break
      (( spans[span + 1] >= first )) || continue
      low=$(( spans[span] + 1 > first ? spans[span] + 1 : first ))
      high=$(( spans[span + 1] < last ? spans[span + 1] : last ))
      (( low <= high )) || continue
      projected+=( $(( prefix_length + low - first )) $(( prefix_length + high - first + 1 ))
        "$spans[span + 2]" )
    done
  fi
  SF_TUI_WRAP_SPANS+=( "${(j: :)projected}" )
}

# Measures each character of LINE in terminal cells.
sf_tui_wrap_cells() {
  local -a characters=( ${(s::)line} )
  integer end=$(( base + ${#characters} ))
  row_start=$base
  sf_tui_wrap_start
  for (( index = base; index < end; index++ )); do
    character=${characters[index - base + 1]}
    if [[ $character == [[:ascii:]] && $character != $'\t' ]]; then
      width=1
    else
      sf_tui_cell_width "$character" $column
      width=$REPLY
    fi
    if (( column + width > columns && ${#display} > prefix_length )); then
      if [[ $character == ' ' ]]; then
        sf_tui_wrap_emit
        row_start=$(( index + 1 ))
      elif (( break_display > prefix_length )); then
        display=( "${(@)display[1,break_display - 1]}" )
        source=( "${(@)source[1,break_display - 1]}" )
        sf_tui_wrap_emit
        row_start=$(( break_source + 1 ))
        index=$break_source
      else
        sf_tui_wrap_emit
        row_start=$index
        index=$(( index - 1 ))
      fi
      (( ! limit || ${#SF_TUI_WRAP_ROWS} < limit )) || return 1
      sf_tui_wrap_start
      continue
    fi
    if [[ $character == $'\t' ]]; then
      repeat $width; do
        display+=( ' ' )
        source+=( $index )
      done
    else
      display+=( "$character" )
      source+=( $index )
    fi
    # Breaking on a leading space would emit an empty row.
    if [[ $character == ' ' ]] && (( ${#display} > prefix_length + 1 )); then
      break_display=${#display}
      break_source=$index
    fi
    column=$(( column + width ))
  done
  (( newline || row_start < end )) || return 0
  sf_tui_wrap_emit
  (( ! limit || ${#SF_TUI_WRAP_ROWS} < limit ))
}

sf_tui_wrap_start() {
  display=( ${(s::)prefix} )
  source=()
  repeat $prefix_length; do source+=( 0 ); done
  column=$prefix_width
  break_display=0
  break_source=0
}

sf_tui_wrap_emit() {
  integer span first last position first_source last_source
  local -a projected=()
  SF_TUI_WRAP_ROWS+=( "${(j::)display}" )
  first_source=${source[prefix_length + 1]:-0}
  last_source=${source[-1]:-0}
  while (( span_head <= ${#spans} && spans[span_head + 1] < first_source )); do
    (( span_head += 3 ))
  done
  for (( span = span_head; span <= ${#spans}; span += 3 )); do
    (( spans[span] < last_source )) || break
    (( spans[span + 1] >= first_source )) || continue
    first=0
    last=0
    for (( position = 1; position <= ${#source}; position++ )); do
      (( source[position] <= spans[span + 1] )) || break
      (( source[position] > spans[span] )) || continue
      (( first )) || first=$position
      last=$position
    done
    (( first )) || continue
    projected+=( $(( first - 1 )) $last "$spans[span + 2]" )
  done
  SF_TUI_WRAP_SPANS+=( "${(j: :)projected}" )
}
