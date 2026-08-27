emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/zselect

typeset -g SF_PRESENT_LAST_PROMPT='' SF_PRESENT_PERMISSION_DRAFT=''
typeset -gi SF_PRESENT_PERMISSION_CURSOR=0
typeset -gi SF_PRESENT_HEARTBEAT_TIMEOUT=1 SF_PRESENT_HEARTBEAT_EPOCHS=10
typeset -gi SF_PRESENT_HEARTBEAT_REMAINING=0
typeset -gi SF_PRESENT_ACTIVITY_FRAME=0 SF_PRESENT_ACTIVITY_TICKS=0
KEYTIMEOUT=$SF_PRESENT_HEARTBEAT_TIMEOUT

# Nothing wakes ZLE while a turn streams, so the view is driven by a synthetic
# key that dispatches the tick. Pending input is the armed state: a queued key
# is a tick that has not run yet, and real input wakes ZLE by itself.
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
  sf_chat_repaint || return 1
  sf_chat_heartbeat_arm
}

sf_chat_record_prompt() {
  if [[ $1 != $SF_PRESENT_LAST_PROMPT ]]; then
    SF_PRESENT_LAST_PROMPT=$1
    print -s -r -- "$1"
  fi
  [[ -z ${HISTNO-} ]] || HISTNO=$HISTCMD
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

sf_chat_bind() {
  SF_PRESENT_LAST_PROMPT=''
  SF_PRESENT_PERMISSION_DRAFT=''
  SF_PRESENT_PERMISSION_CURSOR=0
  SF_PRESENT_HEARTBEAT_REMAINING=0
  zle -N sf_chat_exec_ready
  zle -N sf_chat_heartbeat_tick
  zle -N sf_chat_accept
  zle -N sf_chat_insert
  zle -N sf_chat_insert_newline
  zle -N sf_chat_interrupt
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
  bindkey -M sf-present '^P' up-line-or-history
  bindkey -M sf-present '^N' down-line-or-history
  bindkey -M sf-present $'\e[A' up-line-or-history
  bindkey -M sf-present $'\e[B' down-line-or-history
  bindkey -M sf-present $'\eOA' up-line-or-history
  bindkey -M sf-present $'\eOB' down-line-or-history
  bindkey -M sf-present '^C' sf_chat_interrupt
  bindkey -rpM sf-present $'\x18'
  bindkey -M sf-present $'\x18' sf_chat_heartbeat_tick
  bindkey -M sf-present $'\x18\x1f' sf_chat_heartbeat_tick
  bindkey -M sf-present ' ' sf_chat_insert
  bindkey -M sf-present -R $'!-~' sf_chat_insert
  bindkey -D sf-permission 2>/dev/null || true
  bindkey -N sf-permission
  bindkey -M sf-permission '^M' sf_chat_accept
  bindkey -M sf-permission '^J' sf_chat_accept
  bindkey -M sf-permission '^C' sf_chat_interrupt
  bindkey -M sf-permission 'a' sf_chat_insert
  bindkey -M sf-permission 'd' sf_chat_insert
}
