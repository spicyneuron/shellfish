emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# At most one block is open. Message and reasoning text commits to the ready
# queue one complete line at a time, formatted once at the width the
# transcript last drew. Running executions and the status below an open block
# render fresh on every draw and commit only when they settle.

typeset -g SF_LIVE_KIND='' SF_LIVE_TEXT=''
typeset -g SF_LIVE_ROLE='' SF_LIVE_PRIOR='' SF_LIVE_SECTION=''
typeset -g SF_LIVE_ID='' SF_LIVE_CLASS=''
typeset -g SF_LIVE_PREVIEW='' SF_LIVE_BYPASS='' SF_LIVE_FAILED=''
# SHOWN: the block has committed rows. HIDDEN: its preview budget ran out.
typeset -gi SF_LIVE_SHOWN=0 SF_LIVE_HIDDEN=0 SF_LIVE_HELD=0 SF_LIVE_WORK=0
# Streamed text keeps its own estimate because commits consume the source.
typeset -gi SF_LIVE_TOTAL=0 SF_LIVE_SPENT=0
typeset -g SF_LIVE_TOKENS=''
# The open code fence, if any, after the last committed line.
typeset -g SF_LIVE_STATE=''
# The block index of the provider response being streamed.
typeset -g SF_LIVE_BLOCK=''

# Role runs span formatters, so they outlive any one of them.
typeset -g SF_PRESENT_LAST_ROLE=''
typeset -gi SF_PRESENT_SECTION_ID=0

sf_tui_live_clear() {
  SF_LIVE_KIND=''
  SF_LIVE_TEXT=''
  SF_LIVE_ROLE=''
  SF_LIVE_PRIOR=''
  SF_LIVE_SECTION=''
  SF_LIVE_ID=''
  SF_LIVE_CLASS=''
  SF_LIVE_PREVIEW=''
  SF_LIVE_BYPASS=''
  SF_LIVE_FAILED=''
  SF_LIVE_SHOWN=0
  SF_LIVE_HIDDEN=0
  SF_LIVE_HELD=0
  SF_LIVE_TOTAL=0
  SF_LIVE_SPENT=0
  SF_LIVE_TOKENS=''
  SF_LIVE_STATE=''
}

sf_tui_formatters_reset() {
  sf_tui_live_clear
  SF_LIVE_WORK=0
  SF_LIVE_BLOCK=''
  SF_PRESENT_LAST_ROLE=''
  SF_PRESENT_SECTION_ID=0
}

# Committed rows are built at the width the transcript last drew, so they
# continue the rows the reader is already looking at. They never reflow.
sf_tui_row_width() {
  integer columns=${COLUMNS:-0}
  REPLY=$SF_PRESENT_WIDTH
  [[ -z $REPLY ]] || return 0
  (( columns > 0 )) || columns=80
  REPLY=$(( columns > 1 ? columns - 1 : 1 ))
}

# Only the first formatter of a role run owns its rule.
sf_tui_claim_role() {
  local role=$1
  [[ -n $role && $SF_PRESENT_LAST_ROLE != $role ]] || return 0
  SF_LIVE_ROLE=$role
  SF_LIVE_PRIOR=$SF_PRESENT_LAST_ROLE
  SF_LIVE_SECTION=''
  if [[ $role == (user|agent) ]]; then
    (( ++SF_PRESENT_SECTION_ID ))
    SF_LIVE_SECTION=$SF_PRESENT_SECTION_ID
  fi
  SF_PRESENT_LAST_ROLE=$role
}

# A formatter that never showed anything releases the role it claimed.
sf_tui_retract() {
  if [[ -n $SF_LIVE_ROLE ]] && (( ! SF_LIVE_SHOWN )); then
    [[ -z $SF_LIVE_SECTION ]] ||
      SF_PRESENT_SECTION_ID=$(( SF_PRESENT_SECTION_ID - 1 ))
    SF_PRESENT_LAST_ROLE=$SF_LIVE_PRIOR
  fi
  sf_tui_live_clear
}

# Commit the open block's remaining rows, followed by its separator.
sf_tui_settle() {
  integer columns
  [[ -n $SF_LIVE_KIND ]] || return 0
  if [[ $SF_LIVE_KIND == activity ]]; then
    sf_tui_live_clear
    return 0
  fi
  sf_tui_row_width
  columns=$REPLY
  if [[ $SF_LIVE_KIND == execution ]] || sf_tui_live_deferred; then
    sf_tui_format_execution $columns 1 || return 1
  else
    sf_tui_format_lines $columns 1 || return 1
  fi
  sf_tui_rows_settle
  sf_tui_live_clear
}

# Nothing of substance: drop the formatter instead of settling it.
sf_tui_live_empty() {
  case $SF_LIVE_KIND in
    ''|activity) return 0 ;;
    message|reasoning) (( ! SF_LIVE_SHOWN )) && [[ $SF_LIVE_TEXT != *[!$'\n']* ]] ;;
    *) return 1 ;;
  esac
}

sf_tui_live_close() {
  if sf_tui_live_empty; then
    sf_tui_retract
  else
    sf_tui_settle || return 1
  fi
}

# Presentation actions ------------------------------------------------------

sf_tui_message_open() {
  local role=${1:-agent}
  SF_LIVE_BLOCK=''
  sf_tui_live_close || return 1
  SF_LIVE_KIND=message
  sf_tui_claim_role "$role"
}

# Indexed blocks arrive in order; a new index or kind closes the block before it.
sf_tui_message_stream() {
  local index=$1 content=$2 text=${3-} tokens=${4-} kind=message
  [[ $content != reasoning ]] || kind=reasoning
  [[ -z $SF_LIVE_BLOCK || $SF_LIVE_BLOCK == $index ]] || sf_tui_live_close || return 1
  SF_LIVE_BLOCK=$index
  if [[ $content == inert ]]; then
    sf_tui_live_close || return 1
    sf_tui_activity_resume
    return 0
  fi
  if [[ $SF_LIVE_KIND != $kind ]]; then
    # An opening with nothing shown yet becomes whichever block arrives first.
    if [[ $SF_LIVE_KIND != (message|reasoning) ]] || ! sf_tui_live_empty; then
      sf_tui_live_close || return 1
      sf_tui_live_clear
      sf_tui_claim_role agent
    fi
    SF_LIVE_KIND=$kind
  fi
  if [[ -n $text ]]; then
    sf_tui_safe "$text"
    SF_LIVE_TEXT+=$REPLY
    (( SF_LIVE_TOTAL += ${#REPLY} ))
  fi
  [[ -z $tokens ]] || sf_tui_reasoning_tokens "$tokens"
  sf_tui_rows_commit
}

# The response is complete; the next event decides what runs now.
sf_tui_message_close() {
  SF_LIVE_BLOCK=''
  sf_tui_live_close
}

sf_tui_reasoning_tokens() {
  [[ $SF_LIVE_KIND == reasoning ]] || return 0
  SF_LIVE_TOKENS=$1
}

# One mutable block covers an execution. Hook activity may replace a running
# tool view; the latest visible event owns empty-result settlement.
sf_tui_execution_update() {
  local id=$1 class=${2:-tool} text=${3-} preview=${4-} bypass=${5-}
  if [[ $SF_LIVE_KIND != execution ]]; then
    sf_tui_live_close || return 1
    SF_LIVE_KIND=execution
    SF_LIVE_CLASS=$class
    # A tool call belongs to the agent's turn; a hook notice stands on its own.
    [[ $class != tool ]] || sf_tui_claim_role agent
  fi
  SF_LIVE_ID=$id
  SF_LIVE_PREVIEW=$preview
  SF_LIVE_BYPASS=$bypass
  sf_tui_safe "$text"
  SF_LIVE_TEXT=$REPLY
}

sf_tui_execution_end() {
  local id=$1 class=${2:-tool} text=${3-} preview=${4-} role=${5-} bypass=${6-}
  local failed=${7-}
  # A result with nothing to show leaves no trace, live or settled.
  if [[ -z $text ]]; then
    [[ $SF_LIVE_KIND != execution || $SF_LIVE_ID != $id ]] || sf_tui_retract
    sf_tui_activity_resume
    return 0
  fi
  sf_tui_execution_update "$id" "$class" "$text" "$preview" "$bypass" || return 1
  [[ -z $role ]] || sf_tui_claim_role "$role"
  # A result owns the identity and class of the block it settles.
  SF_LIVE_ID=$id
  SF_LIVE_CLASS=$class
  SF_LIVE_FAILED=$failed
  sf_tui_settle || return 1
  sf_tui_activity_resume
}

sf_tui_error_append() {
  local heading=$1 detail=${2-}
  integer columns
  SF_LIVE_WORK=0
  sf_tui_live_close || return 1
  sf_tui_safe "$heading"
  heading=$REPLY
  sf_tui_safe "$detail"
  detail=$REPLY
  sf_tui_row_width
  columns=$REPLY
  sf_tui_format_notice $columns "✕ $heading" ${#heading} "$detail" || return 1
  sf_tui_rows_settle
  SF_PRESENT_LAST_ROLE=error
}

# Activity ------------------------------------------------------------------

sf_tui_activity_start() {
  SF_LIVE_WORK=1
  SF_LIVE_HELD=0
  sf_tui_activity_resume
}

# A pending decision keeps the block but stops its spinner.
sf_tui_activity_hold() {
  SF_LIVE_HELD=1
}

sf_tui_activity_stop() {
  SF_LIVE_WORK=0
  [[ $SF_LIVE_KIND == activity ]] || return 0
  sf_tui_live_clear
}

sf_tui_activity_resume() {
  (( SF_LIVE_WORK )) || return 0
  [[ -z $SF_LIVE_KIND ]] || return 0
  SF_LIVE_KIND=activity
}

# Row flow ------------------------------------------------------------------

# Clamped reasoning defers its rows until it settles, so its header can report
# what the preview hides.
sf_tui_live_deferred() {
  [[ $SF_LIVE_KIND == reasoning && $SF_PRESENT_PREVIEW_REASONING != full ]]
}

# Commit the open block's complete lines.
sf_tui_rows_commit() {
  ! sf_tui_live_deferred || return 0
  sf_tui_row_width
  sf_tui_format_lines $REPLY 0 || return 1
  sf_tui_rows_append
}

# Render the open block's uncommitted view below the ready queue.
sf_tui_rows_prepare() {
  integer columns=$1
  SF_PRESENT_LIVE_ROW_TEXT=()
  SF_PRESENT_LIVE_ROW_SPANS=()
  sf_tui_format_start
  case $SF_LIVE_KIND in
    '') return 0 ;;
    message) sf_tui_format_status $columns ;;
    reasoning)
      if sf_tui_live_deferred; then sf_tui_format_execution $columns 0
      else sf_tui_format_status $columns; fi ;;
    execution) sf_tui_format_execution $columns 0 ;;
    activity) sf_tui_format_styled $columns "$SF_PRESENT_ACTIVITY" activity ;;
    *) return 1 ;;
  esac || return 1
  SF_PRESENT_LIVE_ROW_TEXT=( "${(@)SF_FORMAT_ROWS}" )
  SF_PRESENT_LIVE_ROW_SPANS=( "${(@)SF_FORMAT_SPANS}" )
}

# A live formatter animates unless a decision is pending.
sf_tui_spinner() {
  (( ! SF_LIVE_HELD ))
}
