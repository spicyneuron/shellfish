emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Wraps logical text into terminal rows and projects source spans onto them.
# Pure: nothing here retains state between calls.
#
# Offsets are characters, not cells, because ZLE's region_highlight counts
# characters. Cells only decide where a row ends.

typeset -ga SF_WRAP_ROWS=() SF_WRAP_SPANS=() SF_WRAP_CONSUMED=()

# sf_tui_wrap COLUMNS TEXT PREFIX [SPAN_START SPAN_END STYLE]...
#
# Each row is PREFIX followed by as much text as fits in COLUMNS cells. Rows
# break at a space when one has content before it, otherwise mid-character-run;
# a break space is consumed and occupies no display offset. A newline ends its
# row and is consumed with it. Input spans are zero-based half-open ranges over
# TEXT and ordered by start; output spans are zero-based over the row, including
# PREFIX.
#
# SF_WRAP_CONSUMED[row] is how much of TEXT that row accounts for, so a caller
# committing a row prefix knows exactly what to drop.
sf_tui_wrap() {
  # Cleared before any rejection, so a caller that ignores the return value
  # reads nothing rather than the previous call's rows.
  SF_WRAP_ROWS=()
  SF_WRAP_SPANS=()
  SF_WRAP_CONSUMED=()
  (( $# >= 3 )) || return 1
  integer columns=$1
  local text=$2 prefix=$3
  shift 3
  local -a spans=( "$@" )
  (( ${#spans} % 3 == 0 && columns > 0 )) || return 1
  local character
  integer index total width column break_display break_source
  integer prefix_width prefix_length row_start span_head=1
  # Display characters of the row being built, and the source index each came
  # from. A tab emits several display characters for one source character;
  # prefix characters have no source and carry 0.
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
        # The space that overflows is the break: absorb it rather than carrying
        # it down to indent the next row.
        sf_tui_wrap_emit $(( index - row_start + 1 ))
        row_start=$(( index + 1 ))
      elif (( break_display > prefix_length )); then
        # Drop the break space and everything after it back to the next row.
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
    # Only a space breaks, and only with content before it: breaking at a row's
    # leading space would emit a blank row instead of making progress.
    if [[ $character == ' ' ]] && (( ${#display} > prefix_length + 1 )); then
      break_display=${#display}
      break_source=$index
    fi
    column=$(( column + width ))
  done
  (( row_start > total )) || sf_tui_wrap_emit $(( total - row_start + 1 ))
}

# Private to sf_tui_wrap, which owns every parameter these two read.
sf_tui_wrap_start() {
  display=( ${(s::)prefix} )
  source=()
  repeat $prefix_length; do source+=( 0 ); done
  column=$prefix_width
  break_display=0
  break_source=0
}

# Closes the row held in $display, projecting every span that touches it.
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
    # Source indexes ascend across the row, so the scan can stop at the first
    # character past the span rather than walking the whole row per span.
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
