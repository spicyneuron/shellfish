emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# The terminal commit boundary. Rows reach scrollback through exactly two
# mechanisms, both preserved here: a descriptor commit (zle -R then zle -I)
# during a turn, and an epoch accept-line while idle. Committed output is
# temporary — row text and style spans only. Nothing here retains a cursor into
# formatter content; a repaint stages the rows it decided are safe, and only a
# successful commit lets the caller apply the consumption those rows represent.

# The contiguous safe prefix the last repaint decided may leave the viewport.
# Only the editor stages and commits these.
typeset -g SF_PRESENT_SAFE_TEXT=''
typeset -ga SF_PRESENT_SAFE_HIGHLIGHTS=()
typeset -gi SF_PRESENT_SAFE_ROWS=0
typeset -g SF_PRESENT_PENDING_TEXT=''
typeset -ga SF_PRESENT_PENDING_HIGHLIGHTS=()
typeset -gi SF_PRESENT_PENDING_ROWS=0
# Whether anything has been committed above the prompt yet.
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

# Freeze the safe rows the last repaint produced, together with the draft they
# will be committed above. The reimplementation must also stage the formatter
# consumption these rows represent, so that sf_tui_terminal_finish can apply it
# and a failed commit can discard it.
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

# Advance presentation state after the caller commits the staged rows. An
# accepted line supplies its newline; a descriptor commit leaves the rows drawn
# and invalidates the display.
sf_tui_terminal_finish() {
  (( SF_PRESENT_PENDING_ROWS )) || return 0
  sf_tui_terminal_sync_start
  PREDISPLAY=$SF_PRESENT_PENDING_TEXT
  BUFFER=''
  CURSOR=0
  POSTDISPLAY=''
  SF_PRESENT_PREFIX_VISIBLE=1
  SF_PRESENT_PENDING_TEXT=''
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
