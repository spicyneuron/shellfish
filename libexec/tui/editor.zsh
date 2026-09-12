emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/zselect
zmodload zsh/zpty

typeset -g SF_PRESENT_PERMISSION_DRAFT=''
typeset -gi SF_PRESENT_PERMISSION_CURSOR=0
typeset -gi SF_PRESENT_HEARTBEAT_TIMEOUT=10
typeset -g SF_PRESENT_HEARTBEAT_FD=''
typeset -gr SF_PRESENT_HEARTBEAT_WORKER=sf-tui-heartbeat
typeset -gi SF_PRESENT_ACTIVITY_FRAME=0
typeset -gi SF_PRESENT_VERTICAL_COLUMN=-1
typeset -g SF_PRESENT_HISTORY_DRAFT=''
typeset -gi SF_PRESENT_HISTORY_CURSOR=0 SF_PRESENT_HISTORY_NO=0
typeset -gi SF_PRESENT_HISTORY_LIMIT=100
typeset -ga SF_PRESENT_HISTORY=()
KEYTIMEOUT=5

# A renderer failure ends the turn loop but not the editor, so the stopped chat
# still accepts /refresh and /quit.
sf_tui_stop() {
  SF_PRESENT_ERROR=$1
  [[ -z ${2-} ]] || SF_PRESENT_ERROR+=$'\n'${2}
  SF_PRESENT_STATE=stopped
  SF_PRESENT_EXIT_STATUS=1
  SF_PRESENT_SAFE_ROWS=0
  sf_tui_heartbeat_stop
  sf_tui_terminal_sync_end force
  sf_tui_stopped_view
}

# Returns nonzero once the chat is stopped, having drawn the stopped view.
sf_tui_repaint_checked() {
  if [[ $SF_PRESENT_STATE == stopped ]]; then
    sf_tui_stopped_view
    return 1
  fi
  if sf_tui_repaint; then
    return 0
  fi
  sf_tui_stop 'cannot render chat'
  return 1
}

sf_tui_draw_pending() {
  PREDISPLAY=$SF_PRESENT_PENDING_TEXT
  BUFFER=''
  CURSOR=0
  POSTDISPLAY=''
  sf_tui_update_highlights pending
}

sf_tui_heartbeat_worker() {
  emulate -L zsh
  zmodload zsh/zselect || exit
  while true; do
    zselect -t "$1" 2>/dev/null || true
    print -n . || exit
  done
}

sf_tui_heartbeat_arm() {
  local mode=${1-} fd
  [[ $SF_PRESENT_STATE == (working|cancelling) || $mode == drain ]] || return 0
  [[ -z $SF_PRESENT_HEARTBEAT_FD ]] || return 0
  zpty -b "$SF_PRESENT_HEARTBEAT_WORKER" sf_tui_heartbeat_worker \
    "$SF_PRESENT_HEARTBEAT_TIMEOUT" || return 1
  fd=$REPLY
  if ! zle -F -w "$fd" sf_tui_heartbeat_ready; then
    zpty -d "$SF_PRESENT_HEARTBEAT_WORKER" 2>/dev/null || true
    return 1
  fi
  SF_PRESENT_HEARTBEAT_FD=$fd
}

sf_tui_heartbeat_stop() {
  local fd=$SF_PRESENT_HEARTBEAT_FD
  SF_PRESENT_HEARTBEAT_FD=''
  [[ -z $fd ]] || zle -F "$fd" 2>/dev/null || true
  zpty -d "$SF_PRESENT_HEARTBEAT_WORKER" 2>/dev/null || true
}

sf_tui_heartbeat_ready() {
  local fd=$1 transport=$SF_TUI_TRANSPORT_OUTPUT_FD
  integer tick_status=0
  if [[ -n ${2-} ]]; then
    sf_tui_heartbeat_stop
    return 1
  fi
  if (( ${KEYS_QUEUED_COUNT:-0} || ${PENDING:-0} )); then
    sf_tui_heartbeat_stop
    return 0
  fi
  while zselect -r "$fd" -t 0 2>/dev/null; do
    read -k 1 -u "$fd" || { sf_tui_heartbeat_stop; return 1; }
  done
  if [[ -n $transport ]] && zselect -r "$transport" -t 0 2>/dev/null; then
    sf_tui_exec_ready "$transport" || return 1
  fi
  sf_tui_heartbeat_tick || tick_status=$?
  (( ! tick_status )) && return 0
  (( tick_status != 2 )) || sf_tui_handoff_exec
  # A live turn can still drain, even degraded. Anything else cannot recover on
  # its own, so stop rather than repaint the failure every interval.
  [[ $SF_PRESENT_STATE == (working|cancelling) ]] || sf_tui_heartbeat_stop
  return $tick_status
}

sf_tui_heartbeat_tick() {
  # The frame follows the clock, not provider traffic.
  if [[ $SF_PRESENT_STATE == working ]]; then
    SF_PRESENT_ACTIVITY_FRAME=$((
      (SF_PRESENT_ACTIVITY_FRAME + 1) % ${#SF_PRESENT_ACTIVITY_FRAMES}
    ))
    SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[SF_PRESENT_ACTIVITY_FRAME + 1]}
  fi
  while true; do
    # A stopped chat has no working renderer to drain events back into.
    if [[ $SF_PRESENT_STATE == stopped ]]; then
      sf_tui_stopped_view
      zle -R
      return 0
    fi
    if sf_tui_transport_has_pending; then
      sf_tui_pending_next || return 1
      continue
    fi
    if sf_tui_transport_is_complete; then
      sf_tui_exec_finish || return 1
      continue
    fi
    if ! sf_tui_repaint_checked; then
      zle -R
      return 0
    fi
    if (( SF_PRESENT_SAFE_ROWS )); then
      sf_tui_terminal_stage || return 1
      # Hold the frame so the commit and the redraw beneath it land together.
      sf_tui_terminal_sync_start
      # `zle -I` keeps what is drawn and continues below it, so drawing the
      # settled rows as the whole display commits exactly those to scrollback.
      # The editor rebuilds from there, so a scroll cannot desynchronise it.
      sf_tui_draw_pending || return 1
      if ! zle -R || ! zle -I; then
        sf_tui_stop 'cannot commit chat rows'
        return 0
      fi
      sf_tui_terminal_finish || return 1
      sf_tui_terminal_restore
      sf_tui_repaint_checked || return 1
      zle -R
      sf_tui_terminal_sync_end
      sf_tui_heartbeat_arm drain
      return
    fi
    zle -R
    # Release a synchronized update even when no rows were committed.
    sf_tui_terminal_sync_end
    if [[ $SF_PRESENT_ACTION == handoff ]]; then
      sf_tui_terminal_sync_end force
      return 2
    elif [[ $SF_PRESENT_ACTION == quit ]]; then
      # A queued /quit leaves through the editor, like a typed one.
      zle accept-line
      return 0
    elif [[ $SF_PRESENT_STATE == queued ]]; then
      SF_PRESENT_STATE=idle
      sf_tui_turn "$SF_PRESENT_SUBMITTED" || return 1
      continue
    else
      sf_tui_heartbeat_arm
    fi
    [[ $SF_PRESENT_STATE == (working|cancelling) ]] || sf_tui_heartbeat_stop
    return
  done
}

sf_tui_line_init() {
  sf_tui_terminal_restore
  sf_tui_transport_watch sf_tui_exec_ready
  if ! sf_tui_repaint_checked; then
    zle -R
    return 0
  fi
  if (( SF_PRESENT_SAFE_ROWS )) && [[ $SF_PRESENT_STATE != working ]]; then
    sf_tui_terminal_stage || return 1
    SF_PRESENT_ACTION=epoch
    sf_tui_draw_pending || return 1
    if ! zle accept-line; then
      SF_PRESENT_ACTION=''
      sf_tui_stop 'cannot commit chat rows'
    fi
  elif [[ $SF_PRESENT_STATE == queued ]]; then
    SF_PRESENT_DRAFT=$BUFFER
    SF_PRESENT_DRAFT_CURSOR=$CURSOR
    SF_PRESENT_DRAFT_SAVED=1
    SF_PRESENT_ACTION=submit
    zle accept-line
  else
    zle -R
    sf_tui_terminal_sync_end
    sf_tui_heartbeat_arm
  fi
}

sf_tui_line_finish() {
  integer pending=$SF_PRESENT_PENDING_ROWS
  if ! sf_tui_terminal_finish; then
    sf_tui_stop 'cannot commit chat rows'
    return 0
  fi
  if (( pending )); then
    sf_tui_update_highlights pending || return 1
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

sf_tui_pre_redraw() {
  (( ! SF_PRESENT_PENDING_ROWS )) || return 0
  if (( SF_PRESENT_HISTORY_NO )) && [[ $SF_PRESENT_STATE != permission &&
      $BUFFER != $SF_PRESENT_HISTORY[$SF_PRESENT_HISTORY_NO] ]]; then
    sf_tui_history_reset
  fi
  sf_tui_repaint_checked || return 0
  sf_tui_heartbeat_arm
}

sf_tui_record_prompt() {
  [[ $1 != ${SF_PRESENT_HISTORY[-1]-} ]] || return 0
  SF_PRESENT_HISTORY+=( "$1" )
  (( ${#SF_PRESENT_HISTORY} <= SF_PRESENT_HISTORY_LIMIT )) || SF_PRESENT_HISTORY[1]=()
}

sf_tui_editor_permission() {
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

sf_tui_accept() {
  local decision=deny intent submitted=$BUFFER
  if [[ $SF_PRESENT_STATE == permission ]]; then
    [[ $BUFFER != a ]] || decision=approve
    if ! sf_tui_answer_permission "$decision"; then
      zle reset-prompt
      zle -R
      return 0
    fi
    zle -R
    return
  fi
  sf_tui_submit "$submitted" || return 1
  intent=$REPLY
  case $intent in
    ignore) return 0 ;;
    repaint)
      sf_tui_history_reset
      BUFFER=''
      CURSOR=0
      sf_tui_repaint_checked
      zle -R
      ;;
    quit) zle accept-line ;;
    submit)
      SF_PRESENT_DRAFT=''
      SF_PRESENT_DRAFT_CURSOR=0
      SF_PRESENT_DRAFT_SAVED=0
      sf_tui_history_reset
      BUFFER=''
      CURSOR=0
      SF_PRESENT_ACTION=submit
      if ! sf_tui_repaint_checked || ! sf_tui_terminal_stage; then
        SF_PRESENT_ACTION=''
        [[ $SF_PRESENT_STATE == stopped ]] || sf_tui_stop 'cannot stage chat rows'
        return 0
      fi
      sf_tui_draw_pending || return 1
      sf_tui_terminal_sync_start
      if ! zle accept-line; then
        SF_PRESENT_ACTION=''
        sf_tui_stop 'cannot commit chat rows'
      fi
      ;;
    *) return 1 ;;
  esac
}

sf_tui_insert_newline() {
  LBUFFER+=$'\n'
}

sf_tui_history_reset() {
  SF_PRESENT_HISTORY_DRAFT=''
  SF_PRESENT_HISTORY_CURSOR=0
  SF_PRESENT_HISTORY_NO=0
}

sf_tui_history_move() {
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
    sf_tui_history_reset
  fi
}

# Move by rendered rows, crossing into history only beyond the buffer edges.
sf_tui_move_vertical() {
  integer direction=$1 columns=${COLUMNS:-0} row column index width
  integer current_row current_column target_row target_column best=-1 distance best_distance=-1
  local character
  local -a rows columns_at
  if (( columns <= 0 )); then
    sf_tui_history_move $direction
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
      sf_tui_cell_width "$character" $column
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
    sf_tui_history_move $direction
    SF_PRESENT_VERTICAL_COLUMN=-1
    return
  fi
  if [[ ${LASTWIDGET-} == (sf_tui_up|sf_tui_down) ]] &&
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

sf_tui_up() {
  sf_tui_move_vertical -1
}

sf_tui_down() {
  sf_tui_move_vertical 1
}

sf_tui_insert() {
  local decision
  if [[ $SF_PRESENT_STATE == permission ]]; then
    case $KEYS in
      a) decision=approve ;;
      d) decision=deny ;;
      *) zle -R; return 0 ;;
    esac
    sf_tui_answer_permission "$decision" || zle reset-prompt
    zle -R
    return 0
  fi
  zle .self-insert
}

sf_tui_interrupt() {
  if [[ $SF_PRESENT_STATE == (idle|stopped) && -n $BUFFER ]]; then
    BUFFER=''
    CURSOR=0
    zle -R
    return
  fi
  sf_tui_cancel || return 1
  if [[ $REPLY == quit ]]; then
    zle accept-line
  else
    zle -R
  fi
}

# Escape cannot be told from the start of an arrow key without an idle window,
# and a streaming turn never provides one, so it cannot carry cancellation:
# Ctrl-C does. It stays bound all the same, because an escape with no exact
# binding leaves the editor waiting for the rest of a sequence that never
# arrives, and the next key then completes a meta binding instead.
sf_tui_escape() {
  zle -R
}

sf_tui_handoff_exec() {
  sf_tui_heartbeat_stop
  [[ $SF_PRESENT_STATE == idle ]] || sf_tui_transport_stop
  zle -I
  stty "$SF_PRESENT_TTY" 2>/dev/null || true
  print
  # A fresh interactive shell prevents the next controller inheriting active ZLE state.
  exec zsh -f -i "${SF_PRESENT_HANDOFF[@]}" </dev/tty >/dev/tty 2>/dev/tty
  print -u2 -r -- 'Cannot execute handoff.'
  exit 1
}

sf_tui_bind() {
  SF_PRESENT_HISTORY=()
  SF_PRESENT_PERMISSION_DRAFT=''
  SF_PRESENT_PERMISSION_CURSOR=0
  SF_PRESENT_HEARTBEAT_FD=''
  SF_PRESENT_VERTICAL_COLUMN=-1
  sf_tui_history_reset
  zle -N sf_tui_exec_ready
  zle -N sf_tui_heartbeat_ready
  zle -N sf_tui_accept
  zle -N sf_tui_insert
  zle -N sf_tui_insert_newline
  zle -N sf_tui_up
  zle -N sf_tui_down
  zle -N sf_tui_interrupt
  zle -N sf_tui_escape
  zle -N zle-line-init sf_tui_line_init
  zle -N zle-line-finish sf_tui_line_finish
  zle -N zle-line-pre-redraw sf_tui_pre_redraw
  bindkey '^M' sf_tui_accept
  bindkey '^J' sf_tui_accept
  bindkey '^[^M' sf_tui_insert_newline
  bindkey $'\e[13;2u' sf_tui_insert_newline
  bindkey '^C' sf_tui_interrupt
  bindkey -D sf-present 2>/dev/null || true
  bindkey -N sf-present emacs
  bindkey -M sf-present '^P' sf_tui_up
  bindkey -M sf-present '^N' sf_tui_down
  bindkey -M sf-present $'\e[A' sf_tui_up
  bindkey -M sf-present $'\e[B' sf_tui_down
  bindkey -M sf-present $'\e[1;1A' sf_tui_up
  bindkey -M sf-present $'\e[1;1B' sf_tui_down
  bindkey -M sf-present $'\eOA' sf_tui_up
  bindkey -M sf-present $'\eOB' sf_tui_down
  bindkey -M sf-present $'\e[3;5~' kill-word
  bindkey -M sf-present '^C' sf_tui_interrupt
  bindkey -M sf-present $'\e' sf_tui_escape
  bindkey -M sf-present ' ' sf_tui_insert
  bindkey -M sf-present -R $'!-~' sf_tui_insert
  bindkey -D sf-permission 2>/dev/null || true
  bindkey -N sf-permission
  bindkey -M sf-permission '^M' sf_tui_accept
  bindkey -M sf-permission '^J' sf_tui_accept
  bindkey -M sf-permission '^C' sf_tui_interrupt
  bindkey -M sf-permission $'\e' sf_tui_escape
  bindkey -M sf-permission 'a' sf_tui_insert
  bindkey -M sf-permission 'd' sf_tui_insert
}
