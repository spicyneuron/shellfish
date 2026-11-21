emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/zselect
zmodload zsh/zpty

typeset -g SF_TUI_PERMISSION_DRAFT=''
typeset -gi SF_TUI_PERMISSION_CURSOR=0
typeset -gi SF_TUI_HEARTBEAT_TIMEOUT=10
typeset -g SF_TUI_HEARTBEAT_FD=''
typeset -gr SF_TUI_HEARTBEAT_WORKER=sf-tui-heartbeat
typeset -gi SF_TUI_ACTIVITY_FRAME=0
typeset -gi SF_TUI_VERTICAL_COLUMN=-1
typeset -g SF_TUI_HISTORY_DRAFT=''
typeset -gi SF_TUI_HISTORY_CURSOR=0 SF_TUI_HISTORY_NO=0
typeset -gi SF_TUI_HISTORY_LIMIT=100
typeset -ga SF_TUI_HISTORY=()
typeset -gi SF_TUI_COMPLETION_START=0
# Pasted images live until the chat ends, so recalled prompts can resend them.
typeset -ga SF_TUI_PASTES=()
KEYTIMEOUT=5

# Keep the editor alive for /refresh and /quit after renderer failure.
sf_tui_stop() {
  SF_TUI_ERROR=$1
  [[ -z ${2-} ]] || SF_TUI_ERROR+=$'\n'${2}
  SF_TUI_STATE=stopped
  SF_TUI_EXIT_STATUS=1
  SF_TUI_SAFE_ROWS=0
  sf_tui_heartbeat_stop
  sf_tui_terminal_sync_end force
  sf_tui_stopped_view
}

sf_tui_repaint_checked() {
  if [[ $SF_TUI_STATE == stopped ]]; then
    sf_tui_stopped_view
    return 1
  fi
  if sf_tui_repaint "${1-}"; then
    return 0
  fi
  sf_tui_stop 'cannot render chat'
  return 1
}

sf_tui_commit() {
  sf_tui_terminal_commit || { sf_tui_stop 'cannot commit chat rows'; return 1; }
}

sf_tui_turn_submitted() {
  SF_TUI_STATE=idle
  sf_tui_turn "$SF_TUI_SUBMITTED" || return 1
  sf_tui_heartbeat_arm || true
}

sf_tui_send_submitted() {
  if ! sf_tui_turn_submitted; then
    SF_TUI_ACTION=failed
    zle accept-line
  else
    zle -R
  fi
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
  [[ $SF_TUI_STATE == (working|permission|cancelling) || $mode == drain ]] || return 0
  [[ -z $SF_TUI_HEARTBEAT_FD ]] || return 0
  zpty -b "$SF_TUI_HEARTBEAT_WORKER" sf_tui_heartbeat_worker \
    "$SF_TUI_HEARTBEAT_TIMEOUT" || return 1
  fd=$REPLY
  if ! zle -F -w "$fd" sf_tui_heartbeat_ready; then
    zpty -d "$SF_TUI_HEARTBEAT_WORKER" 2>/dev/null || true
    return 1
  fi
  SF_TUI_HEARTBEAT_FD=$fd
}

sf_tui_heartbeat_stop() {
  local fd=$SF_TUI_HEARTBEAT_FD
  SF_TUI_HEARTBEAT_FD=''
  [[ -z $fd ]] || zle -F "$fd" 2>/dev/null || true
  zpty -d "$SF_TUI_HEARTBEAT_WORKER" 2>/dev/null || true
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
    sf_tui_turn_ready "$transport" || return 1
  fi
  sf_tui_heartbeat_tick || tick_status=$?
  (( ! tick_status )) && return 0
  (( tick_status != 2 )) || sf_tui_handoff_exec
  # Only an active turn can keep draining after a tick failure.
  [[ $SF_TUI_STATE == (working|permission|cancelling) ]] || sf_tui_heartbeat_stop
  return $tick_status
}

sf_tui_heartbeat_tick() {
  if [[ $SF_TUI_STATE == working ]]; then
    SF_TUI_ACTIVITY_FRAME=$((
      (SF_TUI_ACTIVITY_FRAME + 1) % ${#SF_TUI_ACTIVITY_FRAMES}
    ))
    SF_TUI_ACTIVITY=${SF_TUI_ACTIVITY_FRAMES[SF_TUI_ACTIVITY_FRAME + 1]}
  fi
  while true; do
    if [[ $SF_TUI_STATE == stopped ]]; then
      sf_tui_stopped_view
      zle -R
      return 0
    fi
    if sf_tui_transport_has_pending; then
      sf_tui_pending_next || return 1
      continue
    fi
    if sf_tui_transport_is_complete; then
      sf_tui_turn_finish || return 1
      continue
    fi
    if ! sf_tui_repaint_checked stage; then
      zle -R
      return 0
    fi
    if (( SF_TUI_SAFE_ROWS )); then
      sf_tui_commit || return 0
      sf_tui_repaint_checked || return 1
      zle -R
      sf_tui_terminal_sync_end
      sf_tui_heartbeat_arm drain
      return
    fi
    zle -R
    sf_tui_terminal_sync_end
    if [[ $SF_TUI_ACTION == handoff ]]; then
      sf_tui_terminal_sync_end force
      return 2
    elif [[ $SF_TUI_ACTION == quit ]]; then
      zle accept-line
      return 0
    elif [[ $SF_TUI_STATE == queued ]]; then
      sf_tui_turn_submitted || return 1
      continue
    else
      sf_tui_heartbeat_arm
    fi
    [[ $SF_TUI_STATE == (working|permission|cancelling) ]] || sf_tui_heartbeat_stop
    return
  done
}

sf_tui_line_init() {
  # Working turns render a viewport; other states stage commits.
  local mode=''
  sf_tui_transport_watch sf_tui_turn_ready
  [[ $SF_TUI_STATE == working ]] || mode=stage
  while sf_tui_repaint_checked "$mode" && [[ $mode == stage ]] && (( SF_TUI_SAFE_ROWS )); do
    sf_tui_commit || break
  done
  zle -R
  sf_tui_terminal_sync_end
  sf_tui_heartbeat_arm
}

sf_tui_line_finish() {
  if [[ $SF_TUI_ACTION == (quit|failed) ]]; then
    PREDISPLAY=''
    BUFFER=''
    CURSOR=0
    POSTDISPLAY=''
    region_highlight=()
    zle -R
  fi
}

sf_tui_pre_redraw() {
  (( ! ${SF_TUI_COMMITTING:-0} )) || return 0
  if (( SF_TUI_HISTORY_NO )) && [[ $SF_TUI_STATE != permission &&
      $BUFFER != $SF_TUI_HISTORY[$SF_TUI_HISTORY_NO] ]]; then
    sf_tui_history_reset
  fi
  sf_tui_repaint_checked || return 0
  sf_tui_heartbeat_arm
}

sf_tui_record_prompt() {
  [[ $1 != ${SF_TUI_HISTORY[-1]-} ]] || return 0
  SF_TUI_HISTORY+=( "$1" )
  (( ${#SF_TUI_HISTORY} <= SF_TUI_HISTORY_LIMIT )) || SF_TUI_HISTORY[1]=()
}

sf_tui_editor_permission() {
  local mode=$1
  if [[ $mode == open ]]; then
    SF_TUI_COMPLETIONS=()
    SF_TUI_PERMISSION_DRAFT=${BUFFER-}
    SF_TUI_PERMISSION_CURSOR=${CURSOR:-0}
    BUFFER=''
    CURSOR=0
    return
  fi
  [[ $mode == restore ]] || return 1
  BUFFER=$SF_TUI_PERMISSION_DRAFT
  CURSOR=$SF_TUI_PERMISSION_CURSOR
  SF_TUI_PERMISSION_DRAFT=''
  SF_TUI_PERMISSION_CURSOR=0
}

TRAPWINCH() {
  SF_TUI_VERTICAL_COLUMN=-1
  zle reset-prompt 2>/dev/null || true
}

sf_tui_accept() {
  local intent submitted=$BUFFER
  local -a reply
  sf_tui_submit "$submitted" || return 1
  intent=$REPLY
  case $intent in
    ignore) return 0 ;;
    repaint|notice)
      sf_tui_history_reset
      BUFFER=''
      CURSOR=0
      sf_tui_repaint_checked
      zle -R
      [[ $intent != notice ]] || zle -M "${(F)reply}"
      ;;
    quit) zle accept-line ;;
    submit)
      sf_tui_history_reset
      BUFFER=''
      CURSOR=0
      sf_tui_repaint_checked || return 0
      sf_tui_send_submitted
      ;;
    *) return 1 ;;
  esac
}

sf_tui_insert_newline() {
  LBUFFER+=$'\n'
}

# Leave only settled scrollback behind while another program owns the tty.
sf_tui_external() {
  setopt localoptions localtraps
  local draft=$BUFFER tty
  integer cursor=$CURSOR result=0
  tty=$(stty -g </dev/tty) || return 1
  sf_tui_heartbeat_stop
  sf_tui_transport_unwatch
  trap 'SF_TUI_VERTICAL_COLUMN=-1' WINCH
  {
    PREDISPLAY='' POSTDISPLAY='' BUFFER='' CURSOR=0
    region_highlight=()
    zle -R
    zle -I
    sf_tui_terminal_sync_end force
    stty "$SF_TUI_TTY" </dev/tty
    "$@" </dev/tty >/dev/tty 2>/dev/tty || result=$?
  } always {
    stty "$tty" </dev/tty
    BUFFER=$draft CURSOR=$cursor
    sf_tui_transport_watch sf_tui_turn_ready
    sf_tui_repaint_checked
    zle reset-prompt
    sf_tui_heartbeat_arm drain
  }
  return $result
}

sf_tui_edit_draft() {
  local file edited editor=${VISUAL:-${EDITOR:-vi}}
  file=$(mktemp "${TMPDIR:-/tmp}/shellfish-draft.XXXXXX") || return 1
  {
    print -rn -- "$BUFFER" >"$file" || return 1
    if sf_tui_external ${(@Q)${(z)editor}} "$file"; then
      # Preserve intentional trailing newlines, including an empty draft.
      edited=$(cat -- "$file" && print -n .) || return 1
      BUFFER=${edited%.}
      CURSOR=${#BUFFER}
      sf_tui_history_reset
    fi
  } always { rm -f -- "$file" }
  sf_tui_repaint_checked
  zle -R
}

sf_tui_verbose() {
  local section=$1 file pager=${PAGER:-less -R}
  [[ -n $SF_TUI_SESSION ]] || return 1
  file=$(mktemp "${TMPDIR:-/tmp}/shellfish-verbose.XXXXXX") || return 1
  {
    # Rendering the snapshot in a subshell leaves the live projection intact.
    (
      SF_TUI_PREVIEW=full SF_TUI_PREVIEW_REASONING=full
      sf_tui_load "$SF_TUI_SESSION" "$section" || exit 1
      sf_tui_rows_prepare $(( COLUMNS > 1 ? COLUMNS - 1 : 80 )) || exit 1
      [[ -z $section ]] || (( ${#SF_TUI_ROW_TEXT} + ${#SF_TUI_LIVE_ROW_TEXT} )) || exit 1
      print -rl -- "${SF_TUI_ROW_TEXT[@]}" "${SF_TUI_LIVE_ROW_TEXT[@]}"
    ) >"$file" || return 1
    sf_tui_external ${(@Q)${(z)pager}} "$file"
  } always { rm -f -- "$file" }
}

sf_tui_history_reset() {
  SF_TUI_HISTORY_DRAFT=''
  SF_TUI_HISTORY_CURSOR=0
  SF_TUI_HISTORY_NO=0
}

sf_tui_history_move() {
  integer direction=$1 newest=${#SF_TUI_HISTORY}
  (( newest )) || return 0
  if (( direction < 0 )); then
    if (( SF_TUI_HISTORY_NO )); then
      (( SF_TUI_HISTORY_NO > 1 )) || return 0
      SF_TUI_HISTORY_NO=$(( SF_TUI_HISTORY_NO - 1 ))
    else
      SF_TUI_HISTORY_DRAFT=$BUFFER
      SF_TUI_HISTORY_CURSOR=$CURSOR
      SF_TUI_HISTORY_NO=$newest
    fi
    BUFFER=$SF_TUI_HISTORY[$SF_TUI_HISTORY_NO]
    CURSOR=${#BUFFER}
  elif (( ! SF_TUI_HISTORY_NO )); then
    return 0
  elif (( SF_TUI_HISTORY_NO < newest )); then
    SF_TUI_HISTORY_NO=$(( SF_TUI_HISTORY_NO + 1 ))
    BUFFER=$SF_TUI_HISTORY[$SF_TUI_HISTORY_NO]
    CURSOR=${#BUFFER}
  else
    BUFFER=$SF_TUI_HISTORY_DRAFT
    CURSOR=$SF_TUI_HISTORY_CURSOR
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
    SF_TUI_VERTICAL_COLUMN=-1
    return
  fi
  if [[ ${LASTWIDGET-} == (sf_tui_up|sf_tui_down) ]] &&
      (( SF_TUI_VERTICAL_COLUMN >= 0 )); then
    target_column=$SF_TUI_VERTICAL_COLUMN
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
  SF_TUI_VERTICAL_COLUMN=$target_column
}

sf_tui_up() {
  sf_tui_move_vertical -1
}

sf_tui_down() {
  sf_tui_move_vertical 1
}

# MATCHES replace the range: one outright, several by their shared prefix
# when it extends the typed text. Offsets are zero-based characters, with an
# exclusive end like CURSOR.
sf_tui_complete_range() {
  integer start=$1 end=$2
  shift 2
  local token=${BUFFER:$start:$(( end - start ))} match prefix=''
  SF_TUI_COMPLETIONS=()
  SF_TUI_COMPLETION_NO=0
  SF_TUI_COMPLETION_START=$start
  (( $# )) || return 0
  prefix=$1
  for match in "$@"; do
    while [[ $match != "$prefix"* ]]; do prefix=${prefix%?}; done
  done
  (( $# == 1 )) || [[ $prefix == "$token"* ]] || prefix=$token
  BUFFER="${BUFFER:0:$start}$prefix${BUFFER:$end}"
  CURSOR=$(( start + ${#prefix} ))
  (( $# < 2 )) || SF_TUI_COMPLETIONS=( "$@" )
}

# An open list cycles in STEP's direction, replacing the text inserted so far.
sf_tui_complete_cycle() {
  integer step=$1 count=${#SF_TUI_COMPLETIONS} start=$SF_TUI_COMPLETION_START
  local match
  if (( SF_TUI_COMPLETION_NO )); then
    SF_TUI_COMPLETION_NO=$(( (SF_TUI_COMPLETION_NO - 1 + step + count) % count + 1 ))
  else
    SF_TUI_COMPLETION_NO=$(( step > 0 ? 1 : count ))
  fi
  match=$SF_TUI_COMPLETIONS[SF_TUI_COMPLETION_NO]
  BUFFER="${BUFFER:0:$start}$match${BUFFER:$CURSOR}"
  CURSOR=$(( start + ${#match} ))
}

sf_tui_complete_back() {
  (( ! ${#SF_TUI_COMPLETIONS} )) || sf_tui_complete_cycle -1
}

# Paths complete one folder at a time under the session's working directory.
# A name without a folder also matches deeper file names in a Git work tree.
sf_tui_complete_files() {
  setopt local_options extended_glob
  local word=$1 query=${1#@} cwd=$SF_TUI_CWD listed
  local -a paths=( "$cwd/$query"*(NM) )
  paths=( "${(@)paths#"$cwd/"}" )
  if [[ -n $query && $query != */* ]] &&
      listed=$(git -C "$cwd" ls-files -co --exclude-standard 2>/dev/null); then
    paths+=( ${(M)${(f)listed}:#*/${(b)query}[^/]#} )
  fi
  sf_tui_complete_range $(( CURSOR - ${#word} )) $CURSOR "${(@u)paths/#/@}"
}

# Completes the word ending at the cursor: a leading slash command or an @path.
sf_tui_complete() {
  local word
  if (( ${#SF_TUI_COMPLETIONS} )); then
    sf_tui_complete_cycle 1
    return
  fi
  [[ ${BUFFER:$CURSOR:1} == ([[:space:]]|) ]] || return 0
  word=${${BUFFER:0:$CURSOR}##*[[:space:]]}
  if [[ $word == /* ]] && (( ${#word} == CURSOR )); then
    sf_tui_complete_range 0 $CURSOR ${(M)SF_TUI_COMMANDS:#${(b)word}*}
  elif [[ $word == @* ]]; then
    sf_tui_complete_files "$word"
  fi
}

# Saves the clipboard's image and inserts a marker that attaches it when the
# prompt is sent. Only a captured, supported image gets a marker.
sf_tui_paste_image() {
  local file type pattern='^image/(png|jpeg|gif|webp)$'
  local -a size
  file=$(mktemp "${TMPDIR:-/tmp}/shellfish-paste.XXXXXX") || return 0
  if (( $+commands[osascript] )); then
    osascript -e "set f to open for access POSIX file \"$file\" with write permission" \
      -e 'write (the clipboard as «class PNGf») to f' -e 'close access f'
  elif (( $+commands[wl-paste] )); then
    type=$(wl-paste --list-types | grep -Em 1 "$pattern") && wl-paste --type "$type" >"$file"
  elif (( $+commands[xclip] )); then
    type=$(xclip -selection clipboard -target TARGETS -out | grep -Em 1 "$pattern") &&
      xclip -selection clipboard -target "$type" -out >"$file"
  else
    false
  fi >/dev/null 2>&1 && sf_tui_image_format "$file" || { rm -f -- "$file"; return 0; }
  # Shrinking to fit 2000 pixels is optional, so a failure keeps the original.
  if (( $+commands[magick] )); then
    magick "${file}[0]" -resize '2000x2000>' "$file"
  elif (( $+commands[sips] )); then
    # sips enlarges smaller images, so it resizes only larger ones.
    size=( $(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ { print $2 }') )
    (( ${size[1]:-0} <= 2000 && ${size[2]:-0} <= 2000 )) || sips -Z 2000 "$file"
  fi >/dev/null 2>&1 || true
  SF_TUI_PASTES+=( "$file" )
  LBUFFER+="[Image: $file]"
}

sf_tui_paste_cleanup() {
  (( ! ${#SF_TUI_PASTES} )) || rm -f -- "${SF_TUI_PASTES[@]}"
  SF_TUI_PASTES=()
}

# A key may finish decoding after an asynchronous permission request arrives.
sf_tui_input() {
  local widget=$WIDGET paste
  [[ $widget == (sf_tui_complete|sf_tui_complete_back) ]] || SF_TUI_COMPLETIONS=()
  if [[ $SF_TUI_STATE == permission ]]; then
    case $widget in
      self-insert) sf_tui_permission_choice ;;
      sf_tui_interrupt|sf_tui_send) "$widget" "$@" ;;
      sf_tui_escape) sf_tui_hold_permission || return; "$widget" "$@" ;;
      bracketed-paste) sf_tui_hold_permission || return; zle .bracketed-paste paste ;;
      *) sf_tui_hold_permission || return ;;
    esac
    return 0
  fi
  case $widget in
    sf_tui_accept|sf_tui_send|sf_tui_insert_newline|sf_tui_up|sf_tui_down|sf_tui_interrupt|sf_tui_escape|sf_tui_complete|sf_tui_complete_back|sf_tui_paste_image|sf_tui_edit_draft)
      "$widget" "$@"
      ;;
    *)
      # Consecutive kills append to the cutbuffer only when the wrapper is flagged.
      [[ $widget != *kill* ]] || zle -f kill
      zle ".$widget" -- "$@"
      ;;
  esac
}

# Digits follow the prompt's numbering; letters follow its brackets.
sf_tui_permission_choice() {
  local decision=''
  sf_tui_permission_choices
  case $KEYS in
    ([1-9]) decision=${reply[KEYS]-} ;;
    (a) decision=approve ;;
    (t) decision=approve_session ;;
    (d) decision=deny ;;
    (s) decision=stop ;;
  esac
  if [[ -z $decision ]] || (( ! ${reply[(Ie)$decision]} )); then
    sf_tui_hold_permission || zle reset-prompt
  elif [[ $decision == stop ]]; then
    sf_tui_interrupt
    return
  else
    sf_tui_answer_permission "$decision" || zle reset-prompt
  fi
  zle -R
}

sf_tui_interrupt() {
  if [[ $SF_TUI_STATE == (idle|stopped) && -n $BUFFER ]]; then
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

# Send the draft or the oldest queued prompt, interrupting an active turn.
sf_tui_send() {
  if [[ $SF_TUI_STATE == idle && -z $BUFFER ]] && (( ${#SF_TUI_QUEUE} )); then
    sf_tui_dequeue
    if [[ $SF_TUI_STATE == queued ]]; then
      sf_tui_send_submitted
    else
      zle accept-line
    fi
    return
  fi
  if [[ $SF_TUI_STATE == (idle|stopped) ]]; then
    sf_tui_accept
    return
  fi
  sf_tui_steer || return 1
  zle -R
}

# Bind Escape exactly so ZLE does not wait for a longer sequence.
sf_tui_escape() {
  zle -R
}

sf_tui_handoff_exec() {
  sf_tui_heartbeat_stop
  [[ $SF_TUI_STATE == idle ]] || sf_tui_transport_stop
  zle -I
  print
  # ZLE can overwrite tty settings as it exits; restore in the new process.
  exec zsh -f -c 'stty "$1" < /dev/tty; shift; exec -- "$@"' handoff \
    "$SF_TUI_TTY" "${SF_TUI_HANDOFF[@]}" \
    </dev/tty >/dev/tty 2>/dev/tty
  print -u2 -r -- 'Cannot execute handoff.'
  exit 1
}

sf_tui_bind() {
  SF_TUI_HISTORY=()
  SF_TUI_PERMISSION_DRAFT=''
  SF_TUI_PERMISSION_CURSOR=0
  SF_TUI_HEARTBEAT_FD=''
  SF_TUI_VERTICAL_COLUMN=-1
  sf_tui_history_reset
  zle -N sf_tui_turn_ready
  zle -N sf_tui_heartbeat_ready
  zle -N zle-line-init sf_tui_line_init
  zle -N zle-line-finish sf_tui_line_finish
  zle -N zle-line-pre-redraw sf_tui_pre_redraw
  # Every binding is explicit so each widget passes through sf_tui_input.
  local key widget
  local -a keys=(
    '^M' sf_tui_accept
    '^J' sf_tui_accept
    '^I' sf_tui_complete
    '^[[Z' sf_tui_complete_back
    '^[^M' sf_tui_insert_newline
    '^[[13;2u' sf_tui_insert_newline
    '^X' sf_tui_send
    '^G' sf_tui_edit_draft
    '^[[13;5u' sf_tui_send
    '^[[13;9u' sf_tui_send
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
    '^V' sf_tui_paste_image
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
