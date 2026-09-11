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

# Data field 1 of a message entry is its role.
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
  sf_tui_formatter_append message "$mode" || return 1
  index=$REPLY
  sf_tui_formatter_set_data $index "$role" || return 1
  SF_PRESENT_TEXT[index]=$text
  sf_tui_formatter_role $index "$role"
  REPLY=$index
}

# The rule a role opens: "─ role " padded out to the width, with the section
# number closing it when the role takes one. A number that cannot fit leaves a
# plain rule rather than a truncated one.
#
# Spans are emitted outermost first. The number sits inside the trailing rule,
# so its style has to come after the divider's to survive: region_highlight
# applies spans in order and the last one covering a character wins.
sf_tui_message_rule() {
  integer index=$1 columns=$2 title_end number_start=-1
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
  # The rules either side of the title are one divider, so they share a style.
  sf_tui_span 0 2 divider
  sf_tui_span $title_end ${#text} divider
  sf_tui_span 2 $title_end "section.$role"
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

# Renders a complete message. Every row is safe: the record is durable and
# nothing about it can still change.
sf_tui_format_message() {
  integer index=$1 columns=$2 row
  local body=$SF_PRESENT_TEXT[index] style
  local -a spans=()

  SF_FORMAT_ROWS=()
  SF_FORMAT_SPANS=()
  SF_FORMAT_CONSUMED=()
  SF_FORMAT_SAFE=0

  # Leading blank lines are the previous turn's spacing, and a trailing run
  # collapses to nothing: this formatter owns the blank row above its body.
  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}

  if [[ -n $SF_PRESENT_ROLE[index] ]]; then
    (( index == 1 && ! SF_PRESENT_PREFIX_VISIBLE )) || sf_tui_format_blank
    sf_tui_message_rule $index $columns
    SF_FORMAT_ROWS+=( "$REPLY" )
    SF_FORMAT_CONSUMED+=( 0 )
  fi
  sf_tui_format_blank

  [[ -n $body ]] || { SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}; return 0; }

  SF_PRESENT_HIGHLIGHT_SPANS=()
  (( ! SF_PRESENT_HIGHLIGHT_ENABLED )) || sf_tui_markdown_highlight "$body"
  sf_tui_wrap $columns "$body" '' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  style=${SF_PRESENT_STYLE[message]-}
  for (( row = 1; row <= ${#SF_WRAP_ROWS}; row++ )); do
    SF_FORMAT_ROWS+=( "$SF_WRAP_ROWS[row]" )
    SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
    spans=()
    [[ -z $style || -z $SF_WRAP_ROWS[row] ]] ||
      spans=( 0 ${#SF_WRAP_ROWS[row]} "$style" )
    SF_FORMAT_SPANS+=( "${(j: :)spans} $SF_WRAP_SPANS[row]" )
  done
  SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}

sf_tui_format_blank() {
  SF_FORMAT_ROWS+=( '' )
  SF_FORMAT_SPANS+=( '' )
  SF_FORMAT_CONSUMED+=( 0 )
}
