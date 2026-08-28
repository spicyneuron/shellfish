emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
# $history counts the prompts available to the private chat editor.
zmodload zsh/parameter

# Transient chrome spans are rebuilt by each repaint and indexed across the
# whole displayed string, so they cover POSTDISPLAY as well as PREDISPLAY.
typeset -ga SF_PRESENT_CHROME_HIGHLIGHTS=()
# The most rows whose styling may wait on an inline construct closing. Past this
# the text is styled as it stands, so a full viewport always drains.
typeset -gi SF_PRESENT_HOLD_ROWS=10

sf_chat_chat_start() {
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

sf_chat_chat_end() {
  local session=$1 divider
  integer divider_width=13
  local -a messages=(
    'Good-tide for now!'
    'Thanks for scuttling by.'
    'Time to hit the sand.'
    'Until next tide.'
    'Sea you soon.'
  )
  (( COLUMNS > 1 )) && divider_width=$(( COLUMNS - 1 ))
  divider=${(l:divider_width::─:)""}
  print -r -- "$divider"
  print
  print -r -- $'\e[1mSaved:\e[0m' "$session"
  print
  print -r -- "${messages[RANDOM % ${#messages} + 1]}"
}

sf_chat_chrome() {
  integer start=$1 length=$2
  local style=$SF_PRESENT_STYLE[$3]
  (( length > 0 )) || return 0
  [[ -n $style ]] || return 0
  SF_PRESENT_CHROME_HIGHLIGHTS+=( $start $(( start + length )) "$style" )
}

sf_chat_update_highlights() {
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

sf_chat_repaint() {
  integer columns=${COLUMNS:-0} rows=${LINES:-0} budget reserve=6
  integer index queue_shown queue_limit start queue_head=0 history_item=0 history_label=0
  local divider footer_divider permission label preview queue_item queue_line queue_text=''
  local bottom_style=divider
  local choices='[a]pprove  [d]eny (default)'
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
  sf_chat_highlight_update || return 1
  sf_chat_viewport $columns $budget "$SF_PRESENT_CURSOR" || return 1
  # Wrapping is what discovers a filled row, so a growing line can only be
  # highlighted after the pass that found its boundary, and only then repainted.
  if (( SF_PRESENT_ROW_BOUNDARY_NODE )); then
    sf_chat_highlight_rows $SF_PRESENT_ROW_BOUNDARY_NODE $SF_PRESENT_ROW_BOUNDARY \
      $(( columns * (budget < SF_PRESENT_HOLD_ROWS ? budget : SF_PRESENT_HOLD_ROWS) )) || return 1
    if (( SF_PRESENT_HIGHLIGHT_ADVANCED )); then
      sf_chat_viewport $columns $budget "$SF_PRESENT_CURSOR" || return 1
    fi
  fi
  PREDISPLAY=$SF_PRESENT_VIEWPORT_TEXT
  if [[ -n $PREDISPLAY ]]; then
    PREDISPLAY+=$'\n'
    # The tail reserves the blank row that a fully flushable viewport paints from
    # the prefix, so flushing rows to scrollback never moves the prompt.
    PREDISPLAY+=$'\n'
  elif (( SF_PRESENT_PREFIX_VISIBLE )); then
    PREDISPLAY=$'\n'
  fi
  divider=${(l:columns::─:)""}
  footer_divider=$divider
  if [[ $SF_PRESENT_STATE == permission ]]; then
    bottom_style=permission.divider
    permission="─ Allow $SF_PRESENT_PERMISSION_TOOL outside of sandbox? "
    if (( ${#permission} < columns )); then
      permission+=${(l:$(( columns - ${#permission} ))::─:)""}
    elif (( ${#permission} > columns )); then
      if (( columns > 1 )); then
        permission="${permission[1,$(( columns - 1 ))]}…"
      else
        permission='…'
      fi
    fi
    start=${#PREDISPLAY}
    PREDISPLAY+="$permission"
    sf_chat_chrome $start ${#permission} permission
    PREDISPLAY+=$'\n\n'
    start=${#PREDISPLAY}
    if (( SF_PRESENT_PERMISSION_PREVIEW_LENGTH )); then
      preview=${SF_PRESENT_PERMISSION_TEXT[1,SF_PRESENT_PERMISSION_PREVIEW_LENGTH]}
      SF_PRESENT_HIGHLIGHT_SPANS=()
      sf_chat_code_highlight "$preview" "$SF_PRESENT_PERMISSION_LANGUAGE"
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
    sf_chat_chrome $start ${#choices} permission
  else
    if (( queue_shown )); then
      queue_text='─ queue '
      (( ${#queue_text} >= columns )) ||
        queue_text+=${(l:$(( columns - ${#queue_text} ))::─:)""}
      queue_text=${queue_text[1,columns]}
      queue_head=${#queue_text}
      queue_limit=$(( columns > 7 ? columns - 7 : 0 ))
      for (( index = 1; index <= queue_shown; index++ )); do
        sf_chat_safe "$SF_PRESENT_QUEUE[index]"
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
      sf_chat_chrome $start $queue_head divider
      sf_chat_chrome $(( start + queue_head + 1 )) \
        $(( ${#queue_text} - queue_head - 1 )) muted
    fi
    if [[ -n ${HISTNO-} ]] && (( HISTCMD > HISTNO )); then
      history_item=$(( HISTCMD - HISTNO ))
    fi
    if (( history_item )); then
      label="history $history_item/${#history}"
      if (( ${#label} + 4 <= columns )); then
        divider="─ $label "
        divider+=${(l:$(( columns - ${#label} - 3 ))::─:)""}
        history_label=1
      fi
    fi
    start=${#PREDISPLAY}
    PREDISPLAY+="$divider"$'\n'
    sf_chat_chrome $start ${#divider} divider
    if (( history_label )); then
      sf_chat_chrome $(( start + 2 )) ${#label} muted
    fi
    start=${#PREDISPLAY}
    PREDISPLAY+='❯ '
    sf_chat_chrome $start 2 prompt
  fi
  POSTDISPLAY=$'\n'"$footer_divider"
  sf_chat_chrome $(( ${#PREDISPLAY} + ${#BUFFER} + 1 )) ${#footer_divider} $bottom_style
  if [[ -n $SF_PRESENT_FOOTER ]]; then
    start=$(( ${#PREDISPLAY} + ${#BUFFER} + ${#POSTDISPLAY} + 1 ))
    POSTDISPLAY+=$'\n'"$SF_PRESENT_FOOTER"
    sf_chat_chrome $start ${#SF_PRESENT_FOOTER} footer
  fi
  sf_chat_update_highlights view || return 1
}
