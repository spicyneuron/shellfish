emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/zselect

typeset -g SF_PRESENT_PERMISSION_DRAFT=''
typeset -gi SF_PRESENT_PERMISSION_CURSOR=0
typeset -gi SF_PRESENT_HEARTBEAT_TIMEOUT=1 SF_PRESENT_HEARTBEAT_EPOCHS=10
typeset -gi SF_PRESENT_HEARTBEAT_REMAINING=0
typeset -gi SF_PRESENT_ACTIVITY_FRAME=0 SF_PRESENT_ACTIVITY_TICKS=0
typeset -gi SF_PRESENT_VERTICAL_COLUMN=-1
typeset -g SF_PRESENT_HISTORY_DRAFT=''
typeset -gi SF_PRESENT_HISTORY_CURSOR=0 SF_PRESENT_HISTORY_NO=0
typeset -gi SF_PRESENT_HISTORY_LIMIT=100
typeset -ga SF_PRESENT_HISTORY=()
KEYTIMEOUT=$SF_PRESENT_HEARTBEAT_TIMEOUT

# Nothing wakes ZLE while a turn streams, so the view is driven by a synthetic
# key that dispatches the tick. Its prefix timeout yields to fd callbacks between
# ticks. Real input can arrive behind that prefix, so the keymap must forward
# those combined sequences to their ordinary widgets.
sf_chat_heartbeat_arm() {
  [[ $SF_PRESENT_STATE == (working|cancelling) ]] || return 0
  (( ${KEYS_QUEUED_COUNT:-0} == 0 && ${PENDING:-0} == 0 )) || return 0
  zle -U $'\x18' || return 0
}

sf_chat_heartbeat_tick() {
  if (( ! SF_PRESENT_HEARTBEAT_REMAINING )); then
    zselect -t $SF_PRESENT_HEARTBEAT_TIMEOUT 2>/dev/null || true
    SF_PRESENT_HEARTBEAT_REMAINING=$SF_PRESENT_HEARTBEAT_EPOCHS
    if [[ $SF_PRESENT_STATE == working ]] && (( ++SF_PRESENT_ACTIVITY_TICKS == 2 )); then
      SF_PRESENT_ACTIVITY_TICKS=0
      SF_PRESENT_ACTIVITY_FRAME=$((
        (SF_PRESENT_ACTIVITY_FRAME + 1) % ${#SF_PRESENT_ACTIVITY_FRAMES}
      ))
      SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[SF_PRESENT_ACTIVITY_FRAME + 1]}
    fi
  fi
  while true; do
    sf_chat_repaint || return 1
    if (( SF_PRESENT_FLUSH_ROWS )); then
      SF_PRESENT_HEARTBEAT_REMAINING=$(( SF_PRESENT_HEARTBEAT_REMAINING - 1 ))
      sf_chat_terminal_stage || return 1
      sf_chat_transport_unwatch
      sf_chat_terminal_sync_start
      PREDISPLAY=$SF_PRESENT_PENDING_TEXT
      BUFFER=''
      CURSOR=0
      POSTDISPLAY=''
      sf_chat_update_highlights pending || return 1
      SF_PRESENT_ACTION=epoch
      zle accept-line
      return
    fi
    if sf_chat_transport_has_pending; then
      while sf_chat_transport_has_pending; do
        sf_chat_pending_next || return 1
      done
      continue
    fi
    if sf_chat_transport_is_complete; then
      sf_chat_exec_finish || return 1
      continue
    fi
    zle -R
    # A stream that outruns its epochs ends the chain here rather than in line
    # initialization, so the held view has to be released here too, or nothing
    # is presented until the turn starves.
    sf_chat_terminal_sync_end
    SF_PRESENT_HEARTBEAT_REMAINING=0
    if [[ $SF_PRESENT_ACTION == handoff ]]; then
      zle accept-line
    elif (( SF_PRESENT_EXIT_PENDING )) && [[ $SF_PRESENT_STATE == idle ]]; then
      SF_PRESENT_ACTION=quit
      zle accept-line
    else
      sf_chat_heartbeat_arm
    fi
    return
  done
}

sf_chat_line_init() {
  sf_chat_terminal_restore
  sf_chat_transport_watch sf_chat_exec_ready
  if [[ $SF_PRESENT_STATE == working ]] && (( SF_PRESENT_HEARTBEAT_REMAINING )); then
    sf_chat_heartbeat_tick
    return
  fi
  sf_chat_repaint || return 1
  if (( SF_PRESENT_FLUSH_ROWS )) && [[ $SF_PRESENT_STATE != working ]]; then
    sf_chat_terminal_stage || return 1
    SF_PRESENT_ACTION=epoch
    zle accept-line
  elif (( SF_PRESENT_EXIT_PENDING )) && [[ $SF_PRESENT_STATE == idle ]]; then
    SF_PRESENT_ACTION=quit
    zle accept-line
  elif [[ $SF_PRESENT_STATE == queued ]]; then
    SF_PRESENT_DRAFT=$BUFFER
    SF_PRESENT_DRAFT_CURSOR=$CURSOR
    SF_PRESENT_DRAFT_SAVED=1
    SF_PRESENT_ACTION=submit
    zle accept-line
  else
    zle -R
    sf_chat_terminal_sync_end
    sf_chat_heartbeat_arm
  fi
}

sf_chat_line_finish() {
  integer pending=$SF_PRESENT_PENDING_ROWS
  sf_chat_terminal_finish
  if (( pending )); then
    sf_chat_update_highlights pending || return 1
    zle -R
  elif [[ $SF_PRESENT_ACTION == (submit|quit) ]]; then
    PREDISPLAY=''
    BUFFER=''
    CURSOR=0
    POSTDISPLAY=''
    region_highlight=()
    zle -R
  fi
}

sf_chat_pre_redraw() {
  (( ! SF_PRESENT_PENDING_ROWS )) || return 0
  if (( SF_PRESENT_HISTORY_NO )) && [[ $SF_PRESENT_STATE != permission &&
      $BUFFER != $SF_PRESENT_HISTORY[$SF_PRESENT_HISTORY_NO] ]]; then
    sf_chat_history_reset
  fi
  sf_chat_repaint || return 1
  sf_chat_heartbeat_arm
}

sf_chat_record_prompt() {
  [[ $1 != ${SF_PRESENT_HISTORY[-1]-} ]] || return 0
  SF_PRESENT_HISTORY+=( "$1" )
  (( ${#SF_PRESENT_HISTORY} <= SF_PRESENT_HISTORY_LIMIT )) || SF_PRESENT_HISTORY[1]=()
}

sf_chat_editor_permission() {
  local mode=$1
  if [[ $mode == open ]]; then
    SF_PRESENT_PERMISSION_DRAFT=${BUFFER-}
    SF_PRESENT_PERMISSION_CURSOR=${CURSOR:-0}
    BUFFER=''
    CURSOR=0
    zle -K sf-permission 2>/dev/null || true
    return
  fi
  [[ $mode == (restore|discard) ]] || return 1
  if [[ $mode == restore ]]; then
    BUFFER=$SF_PRESENT_PERMISSION_DRAFT
    CURSOR=$SF_PRESENT_PERMISSION_CURSOR
  fi
  SF_PRESENT_PERMISSION_DRAFT=''
  SF_PRESENT_PERMISSION_CURSOR=0
  zle -K sf-present 2>/dev/null || true
}

TRAPWINCH() {
  SF_PRESENT_VERTICAL_COLUMN=-1
  zle reset-prompt 2>/dev/null || true
}

sf_chat_accept() {
  local decision=deny intent submitted=$BUFFER
  if [[ $SF_PRESENT_STATE == permission ]]; then
    [[ $BUFFER != a ]] || decision=approve
    if ! sf_chat_answer_permission "$decision"; then
      zle reset-prompt
      zle -R
      return 0
    fi
    zle -R
    return
  fi
  sf_chat_submit "$submitted" || return 1
  intent=$REPLY
  case $intent in
    ignore) return 0 ;;
    repaint)
      sf_chat_history_reset
      BUFFER=''
      CURSOR=0
      sf_chat_repaint
      zle -R
      ;;
    quit) zle accept-line ;;
    submit)
      SF_PRESENT_DRAFT=''
      SF_PRESENT_DRAFT_CURSOR=0
      SF_PRESENT_DRAFT_SAVED=0
      sf_chat_history_reset
      BUFFER=''
      CURSOR=0
      sf_chat_repaint || return 1
      sf_chat_terminal_stage || return 1
      SF_PRESENT_ACTION=submit
      zle accept-line
      ;;
    *) return 1 ;;
  esac
}

sf_chat_insert_newline() {
  LBUFFER+=$'\n'
}

sf_chat_history_reset() {
  SF_PRESENT_HISTORY_DRAFT=''
  SF_PRESENT_HISTORY_CURSOR=0
  SF_PRESENT_HISTORY_NO=0
}

sf_chat_history_move() {
  integer direction=$1 newest=${#SF_PRESENT_HISTORY}
  (( newest )) || return 0
  if (( direction < 0 )); then
    if (( SF_PRESENT_HISTORY_NO )); then
      (( SF_PRESENT_HISTORY_NO > 1 )) || return 0
      SF_PRESENT_HISTORY_NO=$(( SF_PRESENT_HISTORY_NO - 1 ))
    else
      SF_PRESENT_HISTORY_DRAFT=$BUFFER
      SF_PRESENT_HISTORY_CURSOR=$CURSOR
      SF_PRESENT_HISTORY_NO=$newest
    fi
    BUFFER=$SF_PRESENT_HISTORY[$SF_PRESENT_HISTORY_NO]
    CURSOR=${#BUFFER}
  elif (( ! SF_PRESENT_HISTORY_NO )); then
    return 0
  elif (( SF_PRESENT_HISTORY_NO < newest )); then
    SF_PRESENT_HISTORY_NO=$(( SF_PRESENT_HISTORY_NO + 1 ))
    BUFFER=$SF_PRESENT_HISTORY[$SF_PRESENT_HISTORY_NO]
    CURSOR=${#BUFFER}
  else
    BUFFER=$SF_PRESENT_HISTORY_DRAFT
    CURSOR=$SF_PRESENT_HISTORY_CURSOR
    sf_chat_history_reset
  fi
}

# Move by rendered rows, crossing into history only beyond the buffer edges.
sf_chat_move_vertical() {
  integer direction=$1 columns=${COLUMNS:-0} row column index width
  integer current_row current_column target_row target_column best=-1 distance best_distance=-1
  local character
  local -a rows columns_at
  if (( columns <= 0 )); then
    sf_chat_history_move $direction
    return
  fi

  # The sf-present buffer starts after the two-cell "❯ " prompt.
  row=$(( 2 / columns ))
  column=$(( 2 % columns ))
  rows=( $row )
  columns_at=( $column )
  for (( index = 1; index <= ${#BUFFER}; ++index )); do
    character=$BUFFER[index]
    if [[ $character == $'\n' ]]; then
      row=$(( row + 1 ))
      column=0
    else
      sf_chat_cell_width "$character" $column
      width=$REPLY
      if (( width && column + width > columns )); then
        row=$(( row + 1 ))
        column=0
      fi
      column=$(( column + width ))
      if (( column >= columns )); then
        row=$(( row + column / columns ))
        column=$(( column % columns ))
      fi
    fi
    rows+=( $row )
    columns_at+=( $column )
  done

  index=$(( CURSOR + 1 ))
  current_row=$rows[index]
  current_column=$columns_at[index]
  target_row=$(( current_row + direction ))
  if (( target_row < rows[1] || target_row > rows[-1] )); then
    sf_chat_history_move $direction
    SF_PRESENT_VERTICAL_COLUMN=-1
    return
  fi
  if [[ ${LASTWIDGET-} == (sf_chat_up|sf_chat_down) ]] &&
      (( SF_PRESENT_VERTICAL_COLUMN >= 0 )); then
    target_column=$SF_PRESENT_VERTICAL_COLUMN
  else
    target_column=$current_column
  fi
  for (( index = 1; index <= ${#rows}; ++index )); do
    (( rows[index] == target_row )) || continue
    distance=$(( columns_at[index] - target_column ))
    (( distance >= 0 )) || distance=$(( -distance ))
    if (( best < 0 || distance <= best_distance )); then
      best=$(( index - 1 ))
      best_distance=$distance
    fi
  done
  CURSOR=$best
  SF_PRESENT_VERTICAL_COLUMN=$target_column
}

sf_chat_up() {
  sf_chat_move_vertical -1
}

sf_chat_down() {
  sf_chat_move_vertical 1
}

sf_chat_insert() {
  local decision
  if [[ $SF_PRESENT_STATE == permission ]]; then
    case $KEYS in
      a) decision=approve ;;
      d) decision=deny ;;
      *) zle -R; return 0 ;;
    esac
    sf_chat_answer_permission "$decision" || zle reset-prompt
    zle -R
    return 0
  fi
  zle .self-insert
}

sf_chat_interrupt() {
  local intent
  if [[ $SF_PRESENT_STATE == (idle|stopped) && -n $BUFFER ]]; then
    BUFFER=''
    CURSOR=0
    zle -R
    return
  fi
  sf_chat_cancel || return 1
  intent=$REPLY
  [[ $intent != reset ]] || zle reset-prompt
  if [[ $intent == quit ]]; then
    zle accept-line
  else
    zle -R
  fi
}

sf_chat_escape() {
  if [[ $KEYS == $'\x18\e' ]]; then
    zle -U $'\e'
    return
  fi
  if [[ $SF_PRESENT_STATE == (working|cancelling|permission) ]]; then
    sf_chat_interrupt
  else
    zle -R
  fi
}

sf_chat_bind() {
  local heartbeat_key=$'\x18' key
  integer code
  SF_PRESENT_HISTORY=()
  SF_PRESENT_PERMISSION_DRAFT=''
  SF_PRESENT_PERMISSION_CURSOR=0
  SF_PRESENT_HEARTBEAT_REMAINING=0
  SF_PRESENT_VERTICAL_COLUMN=-1
  sf_chat_history_reset
  zle -N sf_chat_exec_ready
  zle -N sf_chat_heartbeat_tick
  zle -N sf_chat_accept
  zle -N sf_chat_insert
  zle -N sf_chat_insert_newline
  zle -N sf_chat_up
  zle -N sf_chat_down
  zle -N sf_chat_interrupt
  zle -N sf_chat_escape
  zle -N zle-line-init sf_chat_line_init
  zle -N zle-line-finish sf_chat_line_finish
  zle -N zle-line-pre-redraw sf_chat_pre_redraw
  bindkey '^M' sf_chat_accept
  bindkey '^J' sf_chat_accept
  bindkey '^[^M' sf_chat_insert_newline
  bindkey $'\e[13;2u' sf_chat_insert_newline
  bindkey '^C' sf_chat_interrupt
  bindkey -D sf-present 2>/dev/null || true
  bindkey -N sf-present emacs
  bindkey -M sf-present '^P' sf_chat_up
  bindkey -M sf-present '^N' sf_chat_down
  bindkey -M sf-present $'\e[A' sf_chat_up
  bindkey -M sf-present $'\e[B' sf_chat_down
  bindkey -M sf-present $'\e[1;1A' sf_chat_up
  bindkey -M sf-present $'\e[1;1B' sf_chat_down
  bindkey -M sf-present $'\eOA' sf_chat_up
  bindkey -M sf-present $'\eOB' sf_chat_down
  bindkey -M sf-present '^C' sf_chat_interrupt
  bindkey -M sf-present $'\e' sf_chat_escape
  bindkey -rpM sf-present $'\x18'
  bindkey -M sf-present $'\x18' sf_chat_heartbeat_tick
  bindkey -M sf-present $'\x18\x1f' sf_chat_heartbeat_tick
  bindkey -M sf-present $'\x18\x03' sf_chat_interrupt
  bindkey -M sf-present $'\x18\e' sf_chat_escape
  for code in {32..126}; do
    key=$heartbeat_key${(#)code}
    bindkey -M sf-present "$key" sf_chat_insert
  done
  bindkey -M sf-present ' ' sf_chat_insert
  bindkey -M sf-present -R $'!-~' sf_chat_insert
  bindkey -D sf-permission 2>/dev/null || true
  bindkey -N sf-permission
  bindkey -M sf-permission '^M' sf_chat_accept
  bindkey -M sf-permission '^J' sf_chat_accept
  bindkey -M sf-permission '^C' sf_chat_interrupt
  bindkey -M sf-permission $'\e' sf_chat_escape
  bindkey -M sf-permission 'a' sf_chat_insert
  bindkey -M sf-permission 'd' sf_chat_insert
}
