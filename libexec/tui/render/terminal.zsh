emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Only a successful terminal commit consumes staged rows.
typeset -g SF_PRESENT_SAFE_TEXT=''
typeset -ga SF_PRESENT_SAFE_HIGHLIGHTS=()
typeset -gi SF_PRESENT_SAFE_ROWS=0
typeset -g SF_PRESENT_PENDING_TEXT=''
typeset -ga SF_PRESENT_PENDING_HIGHLIGHTS=()
typeset -gi SF_PRESENT_PENDING_ROWS=0
typeset -gi SF_PRESENT_PREFIX_VISIBLE=0
typeset -g SF_PRESENT_DRAFT=''
typeset -gi SF_PRESENT_DRAFT_CURSOR=0 SF_PRESENT_DRAFT_SAVED=0
typeset -gi SF_PRESENT_SYNC_ACTIVE=0

sf_tui_terminal_reset() {
  SF_PRESENT_PENDING_TEXT=''
  SF_PRESENT_PENDING_HIGHLIGHTS=()
  SF_PRESENT_PENDING_ROWS=0
  SF_PRESENT_SAFE_TEXT=''
  SF_PRESENT_SAFE_HIGHLIGHTS=()
  SF_PRESENT_SAFE_ROWS=0
  SF_PRESENT_DRAFT=''
  SF_PRESENT_DRAFT_CURSOR=0
  SF_PRESENT_DRAFT_SAVED=0
  SF_PRESENT_PREFIX_VISIBLE=0
  SF_PRESENT_SYNC_ACTIVE=0
}

sf_tui_terminal_sync_start() {
  (( ! SF_PRESENT_SYNC_ACTIVE )) || return 0
  SF_PRESENT_SYNC_ACTIVE=1
  if [[ -o zle ]]; then
    print -rn -- $'\e[?2026h'
  fi
  return 0
}

sf_tui_terminal_sync_end() {
  local force=${1-}
  (( SF_PRESENT_SYNC_ACTIVE )) || return 0
  SF_PRESENT_SYNC_ACTIVE=0
  if [[ -o zle || $force == force ]]; then
    print -rn -- $'\e[?2026l'
  fi
  return 0
}

sf_tui_terminal_stage() {
  (( ! SF_PRESENT_PENDING_ROWS )) || return 1
  (( SF_PRESENT_SAFE_ROWS )) || return 1
  SF_PRESENT_PENDING_TEXT=$SF_PRESENT_SAFE_TEXT
  SF_PRESENT_PENDING_ROWS=$SF_PRESENT_SAFE_ROWS
  SF_PRESENT_PENDING_HIGHLIGHTS=( "${(@)SF_PRESENT_SAFE_HIGHLIGHTS}" )
  SF_PRESENT_DRAFT=${BUFFER-}
  SF_PRESENT_DRAFT_CURSOR=${CURSOR:-0}
  SF_PRESENT_DRAFT_SAVED=1
  SF_PRESENT_SAFE_ROWS=0
}

sf_tui_terminal_finish() {
  (( SF_PRESENT_PENDING_ROWS )) || return 0
  PREDISPLAY=$SF_PRESENT_PENDING_TEXT
  BUFFER=''
  CURSOR=0
  POSTDISPLAY=''
  SF_PRESENT_PREFIX_VISIBLE=1
  SF_PRESENT_PENDING_TEXT=''
  sf_tui_rows_consume $SF_PRESENT_PENDING_ROWS || return 1
  SF_PRESENT_PENDING_ROWS=0
}

sf_tui_terminal_restore() {
  (( SF_PRESENT_DRAFT_SAVED )) || return 0
  BUFFER=$SF_PRESENT_DRAFT
  CURSOR=$SF_PRESENT_DRAFT_CURSOR
  SF_PRESENT_DRAFT=''
  SF_PRESENT_DRAFT_CURSOR=0
  SF_PRESENT_DRAFT_SAVED=0
  SF_PRESENT_PENDING_HIGHLIGHTS=()
}
