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

# Keep the editor alive for /refresh and /quit after renderer failure.
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

sf_tui_repaint_checked() {
  if [[ $SF_PRESENT_STATE == stopped ]]; then
    sf_tui_stopped_view
    return 1
  fi
  if sf_tui_repaint "${1-}"; then
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
  sf_tui_update_highlights pending || return 1
  sf_tui_terminal_sync_start
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
  [[ $SF_PRESENT_STATE == (working|permission|cancelling) || $mode == drain ]] || return 0
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
  # Only an active turn can keep draining after a tick failure.
  [[ $SF_PRESENT_STATE == (working|permission|cancelling) ]] || sf_tui_heartbeat_stop
  return $tick_status
}

sf_tui_heartbeat_tick() {
  if [[ $SF_PRESENT_STATE == working ]]; then
    SF_PRESENT_ACTIVITY_FRAME=$((
      (SF_PRESENT_ACTIVITY_FRAME + 1) % ${#SF_PRESENT_ACTIVITY_FRAMES}
    ))
    SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[SF_PRESENT_ACTIVITY_FRAME + 1]}
  fi
  while true; do
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
    if ! sf_tui_repaint_checked stage; then
      zle -R
      return 0
    fi
    if (( SF_PRESENT_SAFE_ROWS )); then
      sf_tui_terminal_stage || return 1
      # Commit settled rows as the entire display, then rebuild below them.
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
    sf_tui_terminal_sync_end
    if [[ $SF_PRESENT_ACTION == handoff ]]; then
      sf_tui_terminal_sync_end force
      return 2
    elif [[ $SF_PRESENT_ACTION == quit ]]; then
      zle accept-line
      return 0
    elif [[ $SF_PRESENT_STATE == queued ]]; then
      SF_PRESENT_STATE=idle
      sf_tui_turn "$SF_PRESENT_SUBMITTED" || return 1
      continue
    else
      sf_tui_heartbeat_arm
    fi
    [[ $SF_PRESENT_STATE == (working|permission|cancelling) ]] || sf_tui_heartbeat_stop
    return
  done
}

sf_tui_line_init() {
  # Working turns render a viewport; other states stage commits.
  local mode=''
  sf_tui_terminal_restore
  sf_tui_transport_watch sf_tui_exec_ready
  [[ $SF_PRESENT_STATE == working ]] || mode=stage
  if ! sf_tui_repaint_checked "$mode"; then
    zle -R
    return 0
  fi
  if (( SF_PRESENT_SAFE_ROWS )) && [[ $mode == stage ]]; then
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
    return
  fi
  [[ $mode == restore ]] || return 1
  BUFFER=$SF_PRESENT_PERMISSION_DRAFT
  CURSOR=$SF_PRESENT_PERMISSION_CURSOR
  SF_PRESENT_PERMISSION_DRAFT=''
  SF_PRESENT_PERMISSION_CURSOR=0
}

TRAPWINCH() {
  SF_PRESENT_VERTICAL_COLUMN=-1
  zle reset-prompt 2>/dev/null || true
}

sf_tui_accept() {
  local intent submitted=$BUFFER
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
      if ! sf_tui_repaint_checked; then
        SF_PRESENT_ACTION=''
        [[ $SF_PRESENT_STATE == stopped ]] || sf_tui_stop 'cannot stage chat rows'
        return 0
      fi
      if sf_tui_terminal_stage prompt; then
        sf_tui_draw_pending || return 1
      elif (( SF_PRESENT_SAFE_ROWS )); then
        SF_PRESENT_ACTION=''
        sf_tui_stop 'cannot stage chat rows'
        return 0
      fi
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

sf_tui_move_vertical() {
  integer direction=$1 columns=${COLUMNS:-0} row column index width
  integer current_row current_column target_row target_column best=-1 distance best_distance=-1
  local character
  local -a rows columns_at
  if (( columns <= 0 )); then
    sf_tui_history_move $direction
    return
  fi

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

# A key may finish decoding after an asynchronous permission request arrives.
sf_tui_input() {
  local widget=$WIDGET paste
  if [[ $SF_PRESENT_STATE == permission ]]; then
    case $widget in
      self-insert) sf_tui_permission_choice ;;
      sf_tui_interrupt|sf_tui_escape) "$widget" "$@" ;;
      bracketed-paste) zle .bracketed-paste paste ;;
    esac
    return 0
  fi
  case $widget in
    sf_tui_accept|sf_tui_insert_newline|sf_tui_up|sf_tui_down|sf_tui_interrupt|sf_tui_escape)
      "$widget" "$@"
      ;;
    *)
      # Consecutive kills append to the cutbuffer only when the wrapper is flagged.
      [[ $widget != *kill* ]] || zle -f kill
      zle ".$widget" -- "$@"
      ;;
  esac
}

sf_tui_permission_choice() {
  local decision
  case $KEYS in
    (a|1) decision=approve ;;
    (d|2) decision=deny ;;
    (s|3) sf_tui_interrupt; return ;;
    *) zle -R; return 0 ;;
  esac
  sf_tui_answer_permission "$decision" || zle reset-prompt
  zle -R
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

# Bind Escape exactly so ZLE does not wait for a longer sequence.
sf_tui_escape() {
  zle -R
}

sf_tui_handoff_exec() {
  sf_tui_heartbeat_stop
  [[ $SF_PRESENT_STATE == idle ]] || sf_tui_transport_stop
  zle -I
  print
  # ZLE can overwrite tty settings as it exits; restore in the new process.
  exec zsh -f -c 'stty "$1" < /dev/tty; shift; exec -- "$@"' handoff \
    "$SF_PRESENT_TTY" "${SF_PRESENT_HANDOFF[@]}" \
    </dev/tty >/dev/tty 2>/dev/tty
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
  zle -N zle-line-init sf_tui_line_init
  zle -N zle-line-finish sf_tui_line_finish
  zle -N zle-line-pre-redraw sf_tui_pre_redraw
  # Every binding is explicit so each widget passes through sf_tui_input.
  local key widget
  local -a keys=(
    '^M' sf_tui_accept
    '^J' sf_tui_accept
    '^[^M' sf_tui_insert_newline
    '^[[13;2u' sf_tui_insert_newline
    '^P' sf_tui_up
    '^N' sf_tui_down
    '^[[A' sf_tui_up
    '^[[B' sf_tui_down
    '^[[1;1A' sf_tui_up
    '^[[1;1B' sf_tui_down
    '^[OA' sf_tui_up
    '^[OB' sf_tui_down
    '^C' sf_tui_interrupt
    '^[' sf_tui_escape
    '^[[200~' bracketed-paste
    '^A' beginning-of-line
    '^E' end-of-line
    '^[[H' beginning-of-line
    '^[[F' end-of-line
    '^[OH' beginning-of-line
    '^[OF' end-of-line
    '^[[1~' beginning-of-line
    '^[[4~' end-of-line
    '^B' backward-char
    '^F' forward-char
    '^[[D' backward-char
    '^[[C' forward-char
    '^[OD' backward-char
    '^[OC' forward-char
    '^[b' backward-word
    '^[f' forward-word
    '^[[1;3D' backward-word
    '^[[1;3C' forward-word
    '^[[1;5D' backward-word
    '^[[1;5C' forward-word
    '^H' backward-delete-char
    '^?' backward-delete-char
    '^D' delete-char
    '^[[3~' delete-char
    '^W' backward-kill-word
    '^[^H' backward-kill-word
    '^[^?' backward-kill-word
    '^[d' kill-word
    '^[[3;5~' kill-word
    '^K' kill-line
    '^U' kill-whole-line
    '^Y' yank
    '^[y' yank-pop
    '^L' clear-screen
  )
  bindkey -D sf-present 2>/dev/null || true
  bindkey -N sf-present
  bindkey -M sf-present -R ' -~' self-insert
  bindkey -M sf-present -R '\M-^@-\M-^?' self-insert
  zle -N self-insert sf_tui_input
  for key widget in "${keys[@]}"; do
    bindkey -M sf-present "$key" "$widget"
    zle -N "$widget" sf_tui_input
  done
}
