emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Span offsets are characters; cells only determine row breaks.

typeset -ga SF_WRAP_ROWS=() SF_WRAP_SPANS=() SF_WRAP_CONSUMED=()

# Spans are ordered, zero-based, half-open ranges over TEXT.
# SF_WRAP_CONSUMED records the source consumed by each row.
sf_tui_wrap() {
  # Rejecting a call never exposes prior output.
  SF_WRAP_ROWS=()
  SF_WRAP_SPANS=()
  SF_WRAP_CONSUMED=()
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
  local character
  integer index total width column break_display break_source
  integer prefix_width prefix_length row_start span_head=1
  # Track each display character's source index; prefix characters use zero.
  local -a display=() source=()

  local -a characters=( ${(s::)text} )
  total=${#characters}
  prefix_length=${#prefix}
  prefix_width=0
  for character in ${(s::)prefix}; do
    sf_tui_cell_width "$character" $prefix_width
    prefix_width=$(( prefix_width + REPLY ))
  done
  (( prefix_width < columns )) || return 1

  sf_tui_wrap_start
  row_start=1
  for (( index = 1; index <= total; index++ )); do
    character=$characters[index]
    if [[ $character == $'\n' ]]; then
      sf_tui_wrap_emit $(( index - row_start + 1 ))
      (( ! limit || ${#SF_WRAP_ROWS} < limit )) || return 0
      row_start=$(( index + 1 ))
      sf_tui_wrap_start
      continue
    fi
    if [[ $character == [[:ascii:]] && $character != $'\t' ]]; then
      width=1
    else
      sf_tui_cell_width "$character" $column
      width=$REPLY
    fi
    if (( column + width > columns && ${#display} > prefix_length )); then
      if [[ $character == ' ' ]]; then
        sf_tui_wrap_emit $(( index - row_start + 1 ))
        row_start=$(( index + 1 ))
      elif (( break_display > prefix_length )); then
        display=( "${(@)display[1,break_display - 1]}" )
        source=( "${(@)source[1,break_display - 1]}" )
        sf_tui_wrap_emit $(( break_source - row_start + 1 ))
        row_start=$(( break_source + 1 ))
        index=$break_source
      else
        sf_tui_wrap_emit $(( index - row_start ))
        row_start=$index
        index=$(( index - 1 ))
      fi
      (( ! limit || ${#SF_WRAP_ROWS} < limit )) || return 0
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
  (( row_start > total )) || sf_tui_wrap_emit $(( total - row_start + 1 ))
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
  integer consumed=$1 span first last position first_source last_source
  local -a projected=()
  SF_WRAP_ROWS+=( "${(j::)display}" )
  SF_WRAP_CONSUMED+=( $consumed )
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
  SF_WRAP_SPANS+=( "${(j: :)projected}" )
}
