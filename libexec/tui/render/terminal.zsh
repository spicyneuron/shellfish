emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Only a successful terminal commit consumes staged rows.
typeset -g SF_TUI_SAFE_TEXT=''
typeset -ga SF_TUI_SAFE_HIGHLIGHTS=()
typeset -gi SF_TUI_SAFE_ROWS=0
typeset -g SF_TUI_PENDING_TEXT=''
typeset -ga SF_TUI_PENDING_HIGHLIGHTS=()
typeset -gi SF_TUI_PENDING_ROWS=0
typeset -gi SF_TUI_PREFIX_VISIBLE=0
typeset -g SF_TUI_DRAFT=''
typeset -gi SF_TUI_DRAFT_CURSOR=0 SF_TUI_DRAFT_SAVED=0
typeset -gi SF_TUI_SYNC_ACTIVE=0

sf_tui_terminal_reset() {
  SF_TUI_PENDING_TEXT=''
  SF_TUI_PENDING_HIGHLIGHTS=()
  SF_TUI_PENDING_ROWS=0
  SF_TUI_SAFE_TEXT=''
  SF_TUI_SAFE_HIGHLIGHTS=()
  SF_TUI_SAFE_ROWS=0
  SF_TUI_DRAFT=''
  SF_TUI_DRAFT_CURSOR=0
  SF_TUI_DRAFT_SAVED=0
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

sf_tui_terminal_stage() {
  integer rows=$SF_TUI_SAFE_ROWS next=$(( SF_TUI_ROW_HEAD + SF_TUI_SAFE_ROWS ))
  (( ! SF_TUI_PENDING_ROWS )) || return 1
  if [[ ${1-} == prompt ]] && (( next == ${#SF_TUI_ROW_TEXT} )) &&
      [[ $SF_TUI_ROW_TEXT[next] == '' && $SF_TUI_ROW_READY[next] == 0 ]]; then
    (( ++rows ))
  fi
  (( rows )) || return 1
  SF_TUI_PENDING_TEXT=$SF_TUI_SAFE_TEXT
  if (( rows > SF_TUI_SAFE_ROWS && SF_TUI_SAFE_ROWS )); then
    SF_TUI_PENDING_TEXT+=$'\n'
  fi
  SF_TUI_PENDING_ROWS=$rows
  SF_TUI_PENDING_HIGHLIGHTS=( "${(@)SF_TUI_SAFE_HIGHLIGHTS}" )
  SF_TUI_DRAFT=${BUFFER-}
  SF_TUI_DRAFT_CURSOR=${CURSOR:-0}
  SF_TUI_DRAFT_SAVED=1
  SF_TUI_SAFE_ROWS=0
}

sf_tui_terminal_finish() {
  (( SF_TUI_PENDING_ROWS )) || return 0
  PREDISPLAY=$SF_TUI_PENDING_TEXT
  BUFFER=''
  CURSOR=0
  POSTDISPLAY=''
  SF_TUI_PREFIX_VISIBLE=1
  SF_TUI_PENDING_TEXT=''
  sf_tui_rows_consume $SF_TUI_PENDING_ROWS || return 1
  SF_TUI_PENDING_ROWS=0
}

sf_tui_terminal_restore() {
  (( SF_TUI_DRAFT_SAVED )) || return 0
  BUFFER=$SF_TUI_DRAFT
  CURSOR=$SF_TUI_DRAFT_CURSOR
  SF_TUI_DRAFT=''
  SF_TUI_DRAFT_CURSOR=0
  SF_TUI_DRAFT_SAVED=0
  SF_TUI_PENDING_HIGHLIGHTS=()
}
