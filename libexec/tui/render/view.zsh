emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -g SF_PRESENT_ERROR=''
typeset -g SF_PRESENT_IDENTITY='' SF_PRESENT_FOOTER=''
typeset -ga SF_PRESENT_COMPLETIONS=()

# Chrome spans cover the full display; viewport spans start at PREDISPLAY.
typeset -ga SF_PRESENT_CHROME_HIGHLIGHTS=()
typeset -g SF_PRESENT_VIEWPORT_TEXT=''
typeset -ga SF_PRESENT_VIEWPORT_HIGHLIGHTS=()
# Rows remain here until committed to terminal scrollback.
typeset -ga SF_PRESENT_ROW_TEXT=() SF_PRESENT_ROW_SPANS=()
typeset -ga SF_PRESENT_ROW_READY=()
typeset -gi SF_PRESENT_ROW_HEAD=1
typeset -ga SF_PRESENT_LIVE_ROW_TEXT=() SF_PRESENT_LIVE_ROW_SPANS=()
# The width the transcript last drew; empty until the first draw.
typeset -g SF_PRESENT_WIDTH=''

sf_tui_reset() {
  SF_PRESENT_COMPLETIONS=()
  SF_PRESENT_ROW_TEXT=()
  SF_PRESENT_ROW_SPANS=()
  SF_PRESENT_ROW_READY=()
  SF_PRESENT_ROW_HEAD=1
  SF_PRESENT_LIVE_ROW_TEXT=()
  SF_PRESENT_LIVE_ROW_SPANS=()
  SF_PRESENT_WIDTH=''
  sf_tui_formatters_reset
}

# A commit ends on a READY row: never role chrome without its content, and
# never a blank row, which ZLE would collapse at the edge of its display.
sf_tui_rows_append() {
  integer row
  for (( row = 1; row <= ${#SF_FORMAT_ROWS}; row++ )); do
    SF_PRESENT_ROW_TEXT+=( "$SF_FORMAT_ROWS[row]" )
    SF_PRESENT_ROW_SPANS+=( "$SF_FORMAT_SPANS[row]" )
    SF_PRESENT_ROW_READY+=( $(( row > SF_FORMAT_LEADING && ${#SF_FORMAT_ROWS[row]} )) )
  done
}

sf_tui_rows_settle() {
  sf_tui_rows_append
  # A separator waits for the next entry or prompt commit.
  SF_PRESENT_ROW_TEXT+=( '' )
  SF_PRESENT_ROW_SPANS+=( '' )
  SF_PRESENT_ROW_READY+=( 0 )
}

sf_tui_rows_consume() {
  integer count=$1 row available=$(( ${#SF_PRESENT_ROW_TEXT} - SF_PRESENT_ROW_HEAD + 1 ))
  (( count >= 0 && count <= available )) || return 1
  for (( row = SF_PRESENT_ROW_HEAD; row < SF_PRESENT_ROW_HEAD + count; row++ )); do
    SF_PRESENT_ROW_TEXT[row]=''
    SF_PRESENT_ROW_SPANS[row]=''
    SF_PRESENT_ROW_READY[row]=0
  done
  SF_PRESENT_ROW_HEAD=$(( SF_PRESENT_ROW_HEAD + count ))
  if (( SF_PRESENT_ROW_HEAD > ${#SF_PRESENT_ROW_TEXT} )); then
    SF_PRESENT_ROW_TEXT=()
    SF_PRESENT_ROW_SPANS=()
    SF_PRESENT_ROW_READY=()
    SF_PRESENT_ROW_HEAD=1
  fi
}

sf_tui_transcript() {
  integer columns=$1 budget=$2 stable take row index total start offset=0 safe_offset=0
  local mode=${3-} text spans

  SF_PRESENT_VIEWPORT_TEXT=''
  SF_PRESENT_VIEWPORT_HIGHLIGHTS=()
  SF_PRESENT_SAFE_TEXT=''
  SF_PRESENT_SAFE_HIGHLIGHTS=()
  SF_PRESENT_SAFE_ROWS=0
  SF_PRESENT_WIDTH=$columns
  sf_tui_rows_prepare $columns || return 1
  stable=$(( ${#SF_PRESENT_ROW_TEXT} - SF_PRESENT_ROW_HEAD + 1 ))
  (( stable > 0 )) || stable=0
  take=$(( stable < budget ? stable : budget ))
  while (( take )) && (( ! SF_PRESENT_ROW_READY[SF_PRESENT_ROW_HEAD + take - 1] )); do
    take=$(( take - 1 ))
  done
  for (( row = 0; row < take; row++ )); do
    index=$(( SF_PRESENT_ROW_HEAD + row ))
    text=$SF_PRESENT_ROW_TEXT[index]
    spans=$SF_PRESENT_ROW_SPANS[index]
    (( row == 0 )) || {
      SF_PRESENT_SAFE_TEXT+=$'\n'
      safe_offset=$(( safe_offset + 1 ))
    }
    sf_tui_shift_spans SF_PRESENT_SAFE_HIGHLIGHTS $safe_offset "$spans"
    SF_PRESENT_SAFE_TEXT+=$text
    safe_offset=$(( safe_offset + ${#text} ))
  done
  SF_PRESENT_SAFE_ROWS=$take
  if [[ $mode == stage ]] && (( take )); then
    return 0
  fi

  total=$(( stable + ${#SF_PRESENT_LIVE_ROW_TEXT} ))
  start=$(( total > budget ? total - budget + 1 : 1 ))
  for (( row = start; row <= total; row++ )); do
    if (( row <= stable )); then
      index=$(( SF_PRESENT_ROW_HEAD + row - 1 ))
      text=$SF_PRESENT_ROW_TEXT[index]
      spans=$SF_PRESENT_ROW_SPANS[index]
    else
      index=$(( row - stable ))
      text=$SF_PRESENT_LIVE_ROW_TEXT[index]
      spans=$SF_PRESENT_LIVE_ROW_SPANS[index]
    fi
    (( row == start )) || {
      SF_PRESENT_VIEWPORT_TEXT+=$'\n'
      offset=$(( offset + 1 ))
    }
    sf_tui_shift_spans SF_PRESENT_VIEWPORT_HIGHLIGHTS $offset "$spans"
    SF_PRESENT_VIEWPORT_TEXT+=$text
    offset=$(( offset + ${#text} ))
  done
}

sf_tui_shift_spans() {
  local name=$1
  integer base=$2 index
  local -a parts=( ${=3} ) shifted=()
  for (( index = 1; index <= ${#parts}; index += 3 )); do
    shifted+=(
      $(( base + parts[index] )) $(( base + parts[index + 1] )) "$parts[index + 2]" )
  done
  set -A "$name" "${(@P)name}" "${(@)shifted}"
}

sf_tui_chat_start() {
  local session_mode=$1 session=$2 line
  local -a logo shrimp
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
  print -r -- $'\e[1mConfig:\e[0m' "${SHELLFISH_DIR-}"
  [[ $session_mode != resume ]] || print -r -- $'\e[1mSession:\e[0m' "$session"
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
  print -r -- $'\e[1mResume with:\e[0m'
  print -r -- "shellfish -s ${(q)session}"
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

# This view must not call the failed renderer.
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

# Permission decisions in prompt order. Listed access may also be approved for
# the session.
sf_tui_permission_choices() {
  reply=( approve deny stop )
  [[ $SF_PRESENT_PERMISSION_KIND != listed ]] || reply[2,1]=( approve_session )
}

sf_tui_divider() {
  integer columns=$1
  sf_tui_clip $columns "─ $2 "
  REPLY+=${(l:$(( columns - ${#REPLY} ))::─:)""}
}

# The returned rows include the heading and a bounded list with overflow.
sf_tui_drawer() {
  integer columns=$1 limit=$2 index shown
  local label=$3
  shift 3
  reply=()
  (( $# )) || return 0
  sf_tui_divider $columns "$label"
  reply+=( "$REPLY" )
  shown=$#
  (( shown <= limit )) || shown=$(( limit - 1 ))
  for (( index = 1; index <= shown; index++ )); do
    sf_tui_clip $columns "$argv[index]"
    reply+=( "$REPLY" )
  done
  if (( shown < $# )); then
    sf_tui_clip $columns "… $(( $# - shown )) more"
    reply+=( "$REPLY" )
  fi
}

sf_tui_repaint() {
  local mode=${1-}
  integer columns=${COLUMNS:-0} rows=${LINES:-0} budget reserve=6
  integer index start head history_item=0 history_label=0
  local prompt_divider_top prompt_divider_bottom label text line
  local prompt_style=prompt
  local choices
  local -a reply drawers=() items=()
  local -A labels
  integer remaining
  if [[ $SF_PRESENT_STATE == idle && ${SF_PRESENT_ACTION-} != submit ]]; then
    prompt_style=prompt_waiting
  fi
  SF_PRESENT_CHROME_HIGHLIGHTS=()
  (( columns > 0 )) || columns=80
  columns=$(( columns > 1 ? columns - 1 : 1 ))
  if [[ $SF_PRESENT_STATE == permission ]]; then
    reserve=$(( 13 + ${#${SF_PRESENT_PERMISSION_TEXT//[^$'\n']}} ))
    [[ $SF_PRESENT_PERMISSION_KIND != listed ]] || (( reserve += 1 ))
    # Raw input is often one long line, so its wrapped rows count too.
    for line in "${(@f)SF_PRESENT_PERMISSION_TEXT}"; do
      reserve+=$(( ${#line} / columns ))
    done
  fi
  if [[ $SF_PRESENT_STATE != permission ]]; then
    for label in queue completions; do
      if [[ $label == queue ]]; then
        items=( "${SF_PRESENT_QUEUE[@]}" )
        for (( index = 1; index <= ${#items}; index++ )); do
          items[index]="$index. $items[index]"
        done
        label='queue (ctrl+x to send now)'
        (( columns >= ${#label} + 3 )) || label=queue
      else
        items=( "${SF_PRESENT_COMPLETIONS[@]}" )
      fi
      sf_tui_drawer $columns 3 "$label" "${items[@]}"
      (( ${#reply} )) || continue
      drawers+=( "${(F)reply}" )
      reserve=$(( reserve + ${#reply} + 1 ))
    done
  fi
  (( rows > reserve )) || rows=$(( reserve + 1 ))
  budget=$(( rows - reserve ))
  sf_tui_transcript $columns $budget "$mode" || return 1
  # A nonempty staging pass commits instead of drawing a viewport.
  [[ $mode != stage ]] || (( ! SF_PRESENT_SAFE_ROWS )) || return 0
  PREDISPLAY=$SF_PRESENT_VIEWPORT_TEXT
  if [[ -n $PREDISPLAY ]]; then
    PREDISPLAY=${PREDISPLAY%$'\n'}$'\n\n'
  elif (( SF_PRESENT_PREFIX_VISIBLE )); then
    PREDISPLAY=$'\n'
  fi
  prompt_divider_top=${(l:columns::─:)""}
  prompt_divider_bottom=$prompt_divider_top
  if [[ $SF_PRESENT_STATE == permission ]]; then
    prompt_style=permission
    if [[ $SF_PRESENT_PERMISSION_KIND == listed ]]; then
      label="Grant $SF_PRESENT_PERMISSION_TOOL this sandbox access?"
    else
      label="Allow $SF_PRESENT_PERMISSION_TOOL outside of sandbox?"
    fi
    sf_tui_divider $columns "$label"
    prompt_divider_top=$REPLY
    start=${#PREDISPLAY}
    PREDISPLAY+="$prompt_divider_top"
    sf_tui_chrome $start ${#prompt_divider_top} $prompt_style
    PREDISPLAY+=$'\n'
    PREDISPLAY+="$SF_PRESENT_PERMISSION_TEXT"$'\n'
    if [[ -n $SF_PRESENT_PERMISSION_REVIEW ]]; then
      PREDISPLAY+="Reviewer: $SF_PRESENT_PERMISSION_REVIEW"$'\n'
    fi
    remaining=$(( SF_PRESENT_PERMISSION_DEADLINE - SECONDS ))
    (( remaining >= 0 )) || remaining=0
    labels=( approve '[a]pprove' approve_session 'approve for [t]his session'
      deny '[d]eny and continue' stop '[s]top and discuss' )
    labels[$SF_PRESENT_PERMISSION_DEFAULT]+=" (${remaining}s)"
    sf_tui_permission_choices
    for index in {1..${#reply}}; do
      reply[index]="$index. $labels[$reply[index]]"
    done
    choices=${(F)reply}
    start=${#PREDISPLAY}
    PREDISPLAY+="$choices"$'\n'
    sf_tui_chrome $start ${#choices} permission
  else
    for text in "${drawers[@]}"; do
      head=${#${text%%$'\n'*}}
      start=${#PREDISPLAY}
      PREDISPLAY+="$text"$'\n\n'
      sf_tui_chrome $start $head divider
      sf_tui_chrome $(( start + 2 )) $(( head > 3 ? head - 3 : 0 )) muted
      sf_tui_chrome $(( start + head + 1 )) $(( ${#text} - head - 1 )) muted
    done
    if (( SF_PRESENT_HISTORY_NO )); then
      history_item=$(( ${#SF_PRESENT_HISTORY} - SF_PRESENT_HISTORY_NO + 1 ))
    fi
    if (( history_item )); then
      label="history $history_item/${#SF_PRESENT_HISTORY}"
      if (( ${#label} + 4 <= columns )); then
        sf_tui_divider $columns "$label"
        prompt_divider_top=$REPLY
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
