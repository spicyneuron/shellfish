emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -g SF_PRESENT_CURSOR='1:0'
typeset -g SF_PRESENT_PENDING_TEXT='' SF_PRESENT_PENDING_CURSOR=''
typeset -ga SF_PRESENT_PENDING_HIGHLIGHTS=()
typeset -gi SF_PRESENT_PENDING_SOURCE_NODE=0 SF_PRESENT_PENDING_SOURCE_OFFSET=0
typeset -g SF_PRESENT_DRAFT=''
typeset -gi SF_PRESENT_DRAFT_CURSOR=0 SF_PRESENT_DRAFT_SAVED=0
typeset -gi SF_PRESENT_PENDING_ROWS=0 SF_PRESENT_SYNC_ACTIVE=0

sf_chat_terminal_reset() {
  SF_PRESENT_CURSOR='1:0'
  SF_PRESENT_PENDING_TEXT=''
  SF_PRESENT_PENDING_CURSOR=''
  SF_PRESENT_PENDING_HIGHLIGHTS=()
  SF_PRESENT_PENDING_ROWS=0
  SF_PRESENT_PENDING_SOURCE_NODE=0
  SF_PRESENT_PENDING_SOURCE_OFFSET=0
  SF_PRESENT_DRAFT=''
  SF_PRESENT_DRAFT_CURSOR=0
  SF_PRESENT_DRAFT_SAVED=0
  SF_PRESENT_PREFIX_VISIBLE=0
  SF_PRESENT_SYNC_ACTIVE=0
}

sf_chat_terminal_sync_start() {
  (( ! SF_PRESENT_SYNC_ACTIVE )) || return 0
  SF_PRESENT_SYNC_ACTIVE=1
  if [[ -o zle ]]; then
    print -rn -- $'\e[?2026h'
  fi
  return 0
}

sf_chat_terminal_sync_end() {
  local force=${1-}
  (( SF_PRESENT_SYNC_ACTIVE )) || return 0
  SF_PRESENT_SYNC_ACTIVE=0
  if [[ -o zle || $force == force ]]; then
    print -rn -- $'\e[?2026l'
  fi
  return 0
}

# Freeze the viewport's current flush before committing it.
sf_chat_terminal_stage() {
  (( ! SF_PRESENT_PENDING_ROWS )) || return 1
  (( SF_PRESENT_FLUSH_ROWS )) || return 1
  SF_PRESENT_PENDING_TEXT=$SF_PRESENT_FLUSH_TEXT
  SF_PRESENT_PENDING_CURSOR=$SF_PRESENT_FLUSH_CURSOR
  SF_PRESENT_PENDING_HIGHLIGHTS=( "${(@)SF_PRESENT_FLUSH_HIGHLIGHTS}" )
  SF_PRESENT_PENDING_ROWS=$SF_PRESENT_FLUSH_ROWS
  SF_PRESENT_PENDING_SOURCE_NODE=$SF_PRESENT_FLUSH_SOURCE_NODE
  SF_PRESENT_PENDING_SOURCE_OFFSET=$SF_PRESENT_FLUSH_SOURCE_OFFSET
  SF_PRESENT_DRAFT=${BUFFER-}
  SF_PRESENT_DRAFT_CURSOR=${CURSOR:-0}
  SF_PRESENT_DRAFT_SAVED=1
  SF_PRESENT_FLUSH_ROWS=0
}

# Advance presentation state after the caller commits the staged rows. An
# accepted line supplies its newline; a descriptor commit leaves the rows drawn
# and invalidates the display.
sf_chat_terminal_finish() {
  integer node offset was_visible=$SF_PRESENT_PREFIX_VISIBLE
  local rest suffix
  (( SF_PRESENT_PENDING_ROWS )) || return 0
  sf_chat_terminal_sync_start
  PREDISPLAY=$SF_PRESENT_PENDING_TEXT
  BUFFER=''
  CURSOR=0
  POSTDISPLAY=''
  SF_PRESENT_PREFIX_VISIBLE=1
  SF_PRESENT_CURSOR=$SF_PRESENT_PENDING_CURSOR
  SF_PRESENT_PENDING_TEXT=''
  SF_PRESENT_PENDING_CURSOR=''
  SF_PRESENT_PENDING_ROWS=0
  if (( SF_PRESENT_PENDING_SOURCE_NODE )); then
    sf_chat_highlight_prune $SF_PRESENT_PENDING_SOURCE_NODE \
      $SF_PRESENT_PENDING_SOURCE_OFFSET || return 1
  fi
  SF_PRESENT_PENDING_SOURCE_NODE=0
  SF_PRESENT_PENDING_SOURCE_OFFSET=0
  node=${SF_PRESENT_CURSOR%%:*}
  if (( ! was_visible && node == 1 )) &&
      [[ $SF_PRESENT_NODE_TYPE[node] != tool_result ]]; then
    rest=${SF_PRESENT_CURSOR#*:}
    if [[ $rest != t:* ]]; then
      offset=${rest%%:*}
      suffix=${rest#$offset}
      SF_PRESENT_CURSOR="1:$(( offset + 1 ))$suffix"
    fi
  fi
  if (( node > 1 )); then
    sf_chat_drop $(( node - 1 )) || return 1
    rest=${SF_PRESENT_CURSOR#*:}
    if [[ $rest == t:* ]]; then
      SF_PRESENT_CURSOR="1:$rest"
    else
      offset=${rest%%:*}
      suffix=${rest#$offset}
      # Only the synthetic separator offset belongs to the dropped prefix.
      (( offset != 1 )) || offset=0
      SF_PRESENT_CURSOR="1:$offset$suffix"
    fi
  fi
}

sf_chat_terminal_restore() {
  (( SF_PRESENT_DRAFT_SAVED )) || return 0
  BUFFER=$SF_PRESENT_DRAFT
  CURSOR=$SF_PRESENT_DRAFT_CURSOR
  SF_PRESENT_DRAFT=''
  SF_PRESENT_DRAFT_CURSOR=0
  SF_PRESENT_DRAFT_SAVED=0
  SF_PRESENT_PENDING_HIGHLIGHTS=()
}
