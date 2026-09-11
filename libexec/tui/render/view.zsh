emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Transient chrome spans are rebuilt by each repaint and indexed across the
# whole displayed string, so they cover POSTDISPLAY as well as PREDISPLAY.
typeset -ga SF_PRESENT_CHROME_HIGHLIGHTS=()
# The rendered transcript and its spans, rebuilt by each repaint and indexed
# from the start of PREDISPLAY.
typeset -g SF_PRESENT_VIEWPORT_TEXT=''
typeset -ga SF_PRESENT_VIEWPORT_HIGHLIGHTS=()
# The contiguous run of leading rows that could leave the viewport.
typeset -gi SF_PRESENT_SAFE_PREFIX=0

# Renders the retained formatters at the current width, keeping the last
# $budget rows. Repaint concatenates what the formatters return; it does not
# lay anything out itself.
#
# The safe prefix is contiguous from the front: it grows while every formatter
# so far has reported all of its rows safe, and stops at the first that has
# not. A formatter with an unsafe row therefore pins everything after it, which
# is what keeps committed scrollback in source order.
sf_tui_transcript() {
  integer columns=$1 budget=$2 index row offset pinned=0 start
  local -a rows=() spans=()

  SF_PRESENT_VIEWPORT_TEXT=''
  SF_PRESENT_VIEWPORT_HIGHLIGHTS=()
  # How many leading rows could be committed, over all retained content rather
  # than only what is drawn. Kept apart from the staging globals the editor
  # commits from: staging also needs the formatter-local consumption these rows
  # represent, and committing without it would repeat them.
  SF_PRESENT_SAFE_PREFIX=0

  for (( index = 1; index <= ${#SF_PRESENT_KIND}; index++ )); do
    case $SF_PRESENT_KIND[index] in
      message) sf_tui_format_message $index $columns || return 1 ;;
      reasoning) sf_tui_format_reasoning $index $columns || return 1 ;;
      *) return 1 ;;
    esac
    for (( row = 1; row <= ${#SF_FORMAT_ROWS}; row++ )); do
      rows+=( "$SF_FORMAT_ROWS[row]" )
      spans+=( "$SF_FORMAT_SPANS[row]" )
    done
    if (( ! pinned )); then
      SF_PRESENT_SAFE_PREFIX=$(( SF_PRESENT_SAFE_PREFIX + SF_FORMAT_SAFE ))
      (( SF_FORMAT_SAFE == ${#SF_FORMAT_ROWS} )) || pinned=1
    fi
  done

  # The budget bounds what is drawn, not what may be committed. Rows above it
  # are the ones on their way to scrollback, so clipping the safe count here
  # would stop the viewport ever draining.
  if (( ${#rows} > budget )); then
    start=$(( ${#rows} - budget + 1 ))
    rows=( "${(@)rows[start,-1]}" )
    spans=( "${(@)spans[start,-1]}" )
  fi

  offset=0
  for (( row = 1; row <= ${#rows}; row++ )); do
    (( row == 1 )) || SF_PRESENT_VIEWPORT_TEXT+=$'\n'
    (( row == 1 )) || offset=$(( offset + 1 ))
    sf_tui_shift_spans $offset "$spans[row]"
    SF_PRESENT_VIEWPORT_TEXT+=$rows[row]
    offset=$(( offset + ${#rows[row]} ))
  done
}

# Appends one row's zero-based spans to the viewport, moved to where the row
# actually sits in PREDISPLAY.
sf_tui_shift_spans() {
  integer base=$1 index
  local -a parts=( ${=2} )
  for (( index = 1; index <= ${#parts}; index += 3 )); do
    SF_PRESENT_VIEWPORT_HIGHLIGHTS+=(
      $(( base + parts[index] )) $(( base + parts[index + 1] )) "$parts[index + 2]" )
  done
}

sf_tui_chat_start() {
  local session_mode=$1 session=$2 tools sandbox line
  local -a details logo shrimp
  details=( "${(@f)$(jq -r '
    ([.harness.tools[].name] | if length == 0 then "none" else join(", ") end),
    (if .harness.sandbox then "enabled" else "disabled" end)
  ' <<<"$SF_PRESENT_RUNTIME")}" ) || return 1
  tools=$details[1]
  sandbox=$details[2]
  logo=(
    '╭─╮╷ ╷╭─╴╷  ╷  ╭─╴╷╭─╮╷ ╷'
    '╰─╮├─┤├╴ │  │  ├╴ │╰─╮├─┤'
    '╰─╯╵ ╵╰─╴╰─╴╰─╴╵  ╵╰─╯╵ ╵'
  )
  shrimp=(
    '╭───────'
    '╰𝆒 ◕ )]]]]]╮'
    '   <<<<<   ⨇'
  )

  print
  if (( COLUMNS >= 41 )); then
    print -r -- $'\e[1m'"$logo[1]"$'\e[0m   '"$shrimp[1]"
    print -r -- $'\e[1m'"$logo[2]"$'\e[0m   '"$shrimp[2]"
    print -r -- $'\e[1m'"$logo[3]"$'\e[0m   '"$shrimp[3]"
  else
    for line in "${logo[@]}"; do
      print -r -- $'\e[1m'"$line"$'\e[0m'
    done
    for line in "${shrimp[@]}"; do
      print -r -- "$line"
    done
  fi
  print
  print -r -- $'\e[1mProject:\e[0m' "$(pwd -P)"
  [[ $session_mode != resume ]] || print -r -- $'\e[1mSession:\e[0m' "$session"
  print -r -- $'\e[1mTools:\e[0m' "$tools"
  print -r -- $'\e[1mSandbox:\e[0m' "$sandbox"
  print
}

sf_tui_chat_end() {
  local session=$1 divider
  integer divider_width=13
  local -a messages=(
    'Good-tide for now.'
    'Thanks for scuttling by.'
    'Time to hit the sand.'
    'Until next tide.'
    'Sea you soon.'
    'Sea you later.'
    'Seas the day!'
    'Just keep swimming.'
  )
  (( COLUMNS > 1 )) && divider_width=$(( COLUMNS - 1 ))
  divider=${(l:divider_width::─:)""}
  print -r -- "$divider"
  print
  print -r -- $'\e[1mSaved:\e[0m' "$session"
  print
  print -r -- "${messages[RANDOM % ${#messages} + 1]}"
}

sf_tui_chrome() {
  integer start=$1 length=$2
  local style=$SF_PRESENT_STYLE[$3]
  (( length > 0 )) || return 0
  [[ -n $style ]] || return 0
  SF_PRESENT_CHROME_HIGHLIGHTS+=( $start $(( start + length )) "$style" )
}

# The view for a client that can no longer draw the transcript. It calls no part
# of the failed renderer, so the offer to refresh or exit always survives.
sf_tui_stopped_view() {
  PREDISPLAY=$'\n'"Shellfish stopped: ${SF_PRESENT_ERROR:-unknown failure}"$'\n\n'
  if [[ -n $SF_PRESENT_SESSION ]]; then
    PREDISPLAY+=$'Submit /refresh to rebuild from the session, or /quit to leave.'
  else
    PREDISPLAY+=$'Submit /quit to leave.'
  fi
  PREDISPLAY+=$'\n\n❯ '
  POSTDISPLAY=''
  region_highlight=()
}

sf_tui_update_highlights() {
  local set=${1:-view}
  local -a spans
  integer index
  case $set in
    view)
      spans=( "${(@)SF_PRESENT_VIEWPORT_HIGHLIGHTS}" "${(@)SF_PRESENT_CHROME_HIGHLIGHTS}" )
      ;;
    pending) spans=( "${(@)SF_PRESENT_PENDING_HIGHLIGHTS}" ) ;;
    *) return 1 ;;
  esac
  region_highlight=()
  for (( index = 1; index <= ${#spans}; index += 3 )); do
    region_highlight+=( "P${spans[index]} ${spans[index + 1]} ${spans[index + 2]}" )
  done
}

sf_tui_repaint() {
  integer columns=${COLUMNS:-0} rows=${LINES:-0} budget reserve=6
  integer index queue_shown queue_limit start queue_head=0 history_item=0 history_label=0
  local prompt_divider_top prompt_divider_bottom label preview
  local queue_item queue_line queue_text=''
  local prompt_style=prompt
  local choices='[a]pprove  [d]eny (default)'
  # Both rules and the glyph are one block and always share a style. Idle is the
  # only state where a prompt submits directly, so it marks the turn as waiting.
  # An accepted prompt repaints before the controller can leave idle, so a submit
  # in flight already belongs to the turn.
  if [[ $SF_PRESENT_STATE == idle && ${SF_PRESENT_ACTION-} != submit ]]; then
    prompt_style=prompt_waiting
  fi
  SF_PRESENT_CHROME_HIGHLIGHTS=()
  (( columns > 0 )) || columns=80
  columns=$(( columns > 1 ? columns - 1 : 1 ))
  # Reserve the transient chrome and ZLE headroom outside the viewport.
  if [[ $SF_PRESENT_STATE == permission ]]; then
    reserve=$(( 11 + ${#${SF_PRESENT_PERMISSION_TEXT//[^$'\n']}} ))
  fi
  queue_shown=0
  if [[ $SF_PRESENT_STATE != permission ]]; then
    queue_shown=$(( ${#SF_PRESENT_QUEUE} < 3 ? ${#SF_PRESENT_QUEUE} : 3 ))
  fi
  if (( queue_shown )); then
    reserve=$(( reserve + queue_shown + 2 + (queue_shown < ${#SF_PRESENT_QUEUE}) ))
  fi
  (( rows > reserve )) || rows=$(( reserve + 1 ))
  budget=$(( rows - reserve ))
  sf_tui_transcript $columns $budget || return 1
  PREDISPLAY=$SF_PRESENT_VIEWPORT_TEXT
  if [[ -n $PREDISPLAY ]]; then
    PREDISPLAY+=$'\n'
    # The tail reserves the blank row that a fully flushable viewport paints from
    # the prefix, so flushing rows to scrollback never moves the prompt.
    PREDISPLAY+=$'\n'
  elif (( SF_PRESENT_PREFIX_VISIBLE )); then
    PREDISPLAY=$'\n'
  fi
  # The two rules are one divider bracketing the buffer, so they always share a
  # style. ZLE splits them because only the top one precedes the edited line.
  prompt_divider_top=${(l:columns::─:)""}
  prompt_divider_bottom=$prompt_divider_top
  if [[ $SF_PRESENT_STATE == permission ]]; then
    prompt_style=permission
    prompt_divider_top="─ Allow $SF_PRESENT_PERMISSION_TOOL outside of sandbox? "
    if (( ${#prompt_divider_top} < columns )); then
      prompt_divider_top+=${(l:$(( columns - ${#prompt_divider_top} ))::─:)""}
    elif (( ${#prompt_divider_top} > columns )); then
      if (( columns > 1 )); then
        prompt_divider_top="${prompt_divider_top[1,$(( columns - 1 ))]}…"
      else
        prompt_divider_top='…'
      fi
    fi
    start=${#PREDISPLAY}
    PREDISPLAY+="$prompt_divider_top"
    sf_tui_chrome $start ${#prompt_divider_top} $prompt_style
    PREDISPLAY+=$'\n\n'
    start=${#PREDISPLAY}
    if (( SF_PRESENT_PERMISSION_PREVIEW_LENGTH )); then
      preview=${SF_PRESENT_PERMISSION_TEXT[1,SF_PRESENT_PERMISSION_PREVIEW_LENGTH]}
      SF_PRESENT_HIGHLIGHT_SPANS=()
      sf_tui_code_highlight "$preview" "$SF_PRESENT_PERMISSION_LANGUAGE"
      for (( index = 1; index <= ${#SF_PRESENT_HIGHLIGHT_SPANS}; index += 3 )); do
        SF_PRESENT_CHROME_HIGHLIGHTS+=(
          $(( start + SF_PRESENT_HIGHLIGHT_SPANS[index] ))
          $(( start + SF_PRESENT_HIGHLIGHT_SPANS[index + 1] ))
          "$SF_PRESENT_HIGHLIGHT_SPANS[index + 2]"
        )
      done
      SF_PRESENT_HIGHLIGHT_SPANS=()
    fi
    PREDISPLAY+="$SF_PRESENT_PERMISSION_TEXT"$'\n\n'
    start=${#PREDISPLAY}
    PREDISPLAY+="$choices"$'\n'
    sf_tui_chrome $start ${#choices} permission
  else
    if (( queue_shown )); then
      queue_text='─ queue '
      (( ${#queue_text} >= columns )) ||
        queue_text+=${(l:$(( columns - ${#queue_text} ))::─:)""}
      queue_text=${queue_text[1,columns]}
      queue_head=${#queue_text}
      queue_limit=$(( columns > 7 ? columns - 7 : 0 ))
      for (( index = 1; index <= queue_shown; index++ )); do
        sf_tui_safe "$SF_PRESENT_QUEUE[index]"
        queue_item=${REPLY//$'\n'/ }
        queue_item=${queue_item//$'\t'/ }
        if (( queue_limit && ${#queue_item} > queue_limit )); then
          queue_item="${queue_item[1,queue_limit - 1]}…"
        fi
        queue_line="$index. $queue_item"
        queue_text+=$'\n'"${queue_line[1,columns]}"
      done
      if (( queue_shown < ${#SF_PRESENT_QUEUE} )); then
        queue_line="… $(( ${#SF_PRESENT_QUEUE} - queue_shown )) more"
        queue_text+=$'\n'"${queue_line[1,columns]}"
      fi
      start=${#PREDISPLAY}
      PREDISPLAY+="$queue_text"$'\n\n'
      sf_tui_chrome $start $queue_head divider
      sf_tui_chrome $(( start + 2 )) $(( queue_head - 2 < 5 ? queue_head - 2 : 5 )) muted
      sf_tui_chrome $(( start + queue_head + 1 )) \
        $(( ${#queue_text} - queue_head - 1 )) muted
    fi
    if (( SF_PRESENT_HISTORY_NO )); then
      history_item=$(( ${#SF_PRESENT_HISTORY} - SF_PRESENT_HISTORY_NO + 1 ))
    fi
    if (( history_item )); then
      label="history $history_item/${#SF_PRESENT_HISTORY}"
      if (( ${#label} + 4 <= columns )); then
        prompt_divider_top="─ $label "
        prompt_divider_top+=${(l:$(( columns - ${#label} - 3 ))::─:)""}
        history_label=1
      fi
    fi
    start=${#PREDISPLAY}
    PREDISPLAY+="$prompt_divider_top"$'\n'
    sf_tui_chrome $start ${#prompt_divider_top} $prompt_style
    if (( history_label )); then
      sf_tui_chrome $(( start + 2 )) ${#label} muted
    fi
    start=${#PREDISPLAY}
    PREDISPLAY+='❯ '
    sf_tui_chrome $start 2 $prompt_style
  fi
  POSTDISPLAY=$'\n'"$prompt_divider_bottom"
  sf_tui_chrome $(( ${#PREDISPLAY} + ${#BUFFER} + 1 )) \
    ${#prompt_divider_bottom} $prompt_style
  if [[ -n $SF_PRESENT_FOOTER ]]; then
    start=$(( ${#PREDISPLAY} + ${#BUFFER} + ${#POSTDISPLAY} + 1 ))
    POSTDISPLAY+=$'\n'"$SF_PRESENT_FOOTER"
    sf_tui_chrome $start ${#SF_PRESENT_FOOTER} footer
  fi
  sf_tui_update_highlights view || return 1
}
