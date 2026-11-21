emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -g SF_TUI_SAFE_TEXT=''
typeset -ga SF_TUI_SAFE_HIGHLIGHTS=()
typeset -gi SF_TUI_SAFE_ROWS=0
typeset -gi SF_TUI_PREFIX_VISIBLE=0
typeset -gi SF_TUI_SYNC_ACTIVE=0

sf_tui_terminal_reset() {
  SF_TUI_SAFE_TEXT=''
  SF_TUI_SAFE_HIGHLIGHTS=()
  SF_TUI_SAFE_ROWS=0
  SF_TUI_PREFIX_VISIBLE=0
  SF_TUI_SYNC_ACTIVE=0
}

sf_tui_terminal_sync_start() {
  (( ! SF_TUI_SYNC_ACTIVE )) || return 0
  if [[ -o zle ]]; then
    SF_TUI_SYNC_ACTIVE=1
    print -rn -- $'\e[?2026h'
  fi
  return 0
}

sf_tui_terminal_sync_end() {
  local force=${1-}
  (( SF_TUI_SYNC_ACTIVE )) || return 0
  if [[ -o zle || $force == force ]]; then
    print -rn -- $'\e[?2026l'
    # SIGTERM must still close the frame if it interrupts the write.
    SF_TUI_SYNC_ACTIVE=0
  fi
  return 0
}

# Leave settled rows on the terminal before restoring the draft below them.
sf_tui_terminal_commit() {
  (( SF_TUI_SAFE_ROWS )) || return 1
  local draft=${BUFFER-}
  integer cursor=${CURSOR:-0} SF_TUI_COMMITTING=1
  {
    PREDISPLAY=$SF_TUI_SAFE_TEXT
    BUFFER='' CURSOR=0 POSTDISPLAY=''
    sf_tui_update_highlights safe || return 1
    sf_tui_terminal_sync_start
    zle -R && zle -I && sf_tui_rows_consume $SF_TUI_SAFE_ROWS || return 1
    SF_TUI_PREFIX_VISIBLE=1
    SF_TUI_SAFE_ROWS=0
  } always {
    BUFFER=$draft CURSOR=$cursor
  }
}
