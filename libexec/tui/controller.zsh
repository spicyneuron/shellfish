emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -ga SF_PRESENT_HANDOFF=() SF_PRESENT_QUEUE=()
# The durable session, empty until creation announces one.
typeset -g SF_PRESENT_SESSION=''
typeset -g SF_PRESENT_ACTION='' SF_PRESENT_SUBMITTED=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_PERMISSION_ID=''
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -g SF_PRESENT_PERMISSION_LANGUAGE=''
typeset -gi SF_PRESENT_PERMISSION_PREVIEW_LENGTH=0
typeset -gi SF_PRESENT_EXIT_STATUS=0
# Set when the turn persisted its own failure, which the reload then replays.
typeset -gi SF_PRESENT_TURN_ERROR=0
typeset -g SF_PRESENT_TTY=''

sf_tui_permission_reset() {
  SF_PRESENT_PERMISSION_ID=''
  SF_PRESENT_PERMISSION_TOOL=''
  SF_PRESENT_PERMISSION_TEXT=''
  SF_PRESENT_PERMISSION_LANGUAGE=''
  SF_PRESENT_PERMISSION_PREVIEW_LENGTH=0
}

TRAPTERM() {
  sf_tui_terminal_sync_end force
  [[ $SF_PRESENT_STATE == idle ]] || sf_tui_transport_stop
  exit 143
}

sf_tui_discard_queue() {
  integer count=${#SF_PRESENT_QUEUE}
  SF_PRESENT_QUEUE=()
  REPLY=''
  (( count )) || return 0
  REPLY="Discarded $count queued prompt"
  (( count == 1 )) || REPLY+='s'
  REPLY+='. Use ↑↓ keys to recover.'
}

# Leaving and rebuilding the client are its own lifecycle rather than the
# session's, so it answers these without a turn. That keeps them working when a
# stopped chat can no longer run one, and keeps a queued one out of the provider
# request it would otherwise become.
sf_tui_client_command() {
  case $1 in
    /quit|/q)
      SF_PRESENT_ACTION=quit
      ;;
    /refresh|/r)
      [[ -n $SF_PRESENT_SESSION ]] || return 1
      SF_PRESENT_HANDOFF=( "$SF_ENTRY" --clear --session "$SF_PRESENT_SESSION" )
      SF_PRESENT_ACTION=handoff
      ;;
    *) return 1 ;;
  esac
}

sf_tui_submit() {
  local submitted=$1
  integer queue_index
  REPLY=ignore
  if [[ $submitted =~ '^/queue[[:space:]]+clear[[:space:]]*$' ]]; then
    SF_PRESENT_QUEUE=()
    REPLY=repaint
    return
  fi
  if [[ $submitted =~ '^/queue[[:space:]]+drop[[:space:]]+([0-9]+)[[:space:]]*$' ]]; then
    queue_index=$match[1]
    (( queue_index >= 1 && queue_index <= ${#SF_PRESENT_QUEUE} )) || return 0
    SF_PRESENT_QUEUE[queue_index]=()
    REPLY=repaint
    return
  fi
  [[ $submitted != /queue([[:space:]]|$)* ]] || return 0
  if [[ $SF_PRESENT_STATE == (working|queued) ]]; then
    [[ -n $submitted ]] || return 0
    SF_PRESENT_QUEUE+=( "$submitted" )
    sf_tui_record_prompt "$submitted"
    REPLY=repaint
    return
  fi
  if [[ $SF_PRESENT_STATE == (idle|stopped) ]] && sf_tui_client_command "$submitted"; then
    REPLY=quit
    return
  fi
  [[ $SF_PRESENT_STATE == idle && -n $submitted ]] || return 0
  SF_PRESENT_SUBMITTED=$submitted
  sf_tui_record_prompt "$submitted"
  sf_tui_event user "$submitted" || return 1
  REPLY=submit
}

sf_tui_cancel() {
  REPLY=redraw
  case $SF_PRESENT_STATE in
    queued) return ;;
    cancelling)
      SF_PRESENT_EXIT_STATUS=130
      SF_PRESENT_ACTION=quit
      REPLY=quit
      return
      ;;
    permission|working)
      [[ $SF_PRESENT_STATE != permission ]] || sf_tui_editor_permission restore
      SF_PRESENT_STATE=cancelling
      sf_tui_transport_signal USR1
      return
      ;;
    idle|stopped)
      SF_PRESENT_EXIT_STATUS=130
      SF_PRESENT_ACTION=quit
      REPLY=quit
      ;;
  esac
}

sf_tui_decoded() {
  local type=$1 first=${2-} second=${3-} third=${4-} fourth=${5-} fifth=${6-} sixth=${7-}
  local encoded preview reason
  # Only creation events are legal before a durable session exists.
  [[ -n $SF_PRESENT_SESSION ||
      $type == (hook_activity|hook_result|error|session_created) ]] ||
    return 1
  case $type in
      session_created)
        [[ -z $SF_PRESENT_SESSION ]] || return 1
        SF_PRESENT_SESSION=$first
        SF_TUI_TRANSPORT_COMMAND=( "$SF_ENTRY" run --jsonl --session "$first" )
        ;;
      assistant_start|assistant_message_delta|assistant_reasoning_delta| \
      assistant_reasoning_opaque|assistant_tool_call_delta|assistant_end| \
      tool_call|tool_result|hook_activity|hook_result)
        sf_tui_event "$type" "$first" "$second" "$third" "$fourth" "$fifth" "$sixth" || return 1
        ;;
      turn_usage)
        sf_tui_footer_usage "$first"
        [[ -z $second ]] || sf_tui_event reasoning_tokens "$second" || return 1
        ;;
      error)
        sf_tui_event error "$first" "$second" "$third" || return 1
        [[ $third != end ]] || SF_PRESENT_TURN_ERROR=1
        ;;
      permission_request)
        [[ $SF_PRESENT_STATE == working && -z $SF_PRESENT_PERMISSION_ID ]] || return 1
        SF_PRESENT_PERMISSION_ID=$first
        sf_tui_safe "$second"
        SF_PRESENT_PERMISSION_TOOL=$REPLY
        sf_tui_safe "$third"
        preview=$REPLY
        sf_tui_safe "$fourth"
        reason=$REPLY
        SF_PRESENT_PERMISSION_TEXT="$preview"$'\n\nReason: '"$reason"
        SF_PRESENT_PERMISSION_LANGUAGE=$fifth
        SF_PRESENT_PERMISSION_PREVIEW_LENGTH=${#preview}
        sf_tui_editor_permission open
        SF_PRESENT_STATE=permission
        sf_tui_event tool_permission || return 1
        ;;
      handoff)
        (( ! ${#SF_PRESENT_HANDOFF} )) || return 1
        encoded=$(jq -j '.[] | ., "\u0000"' <<<"$first") || return 1
        SF_PRESENT_HANDOFF=( "${(@0)${encoded%$'\0'}}" )
        ;;
      session_update)
        sf_tui_session_update "$first"
        ;;
      *) return 1 ;;
  esac
}

# Apply one transport record.
sf_tui_pending_next() {
  integer transport_status=0

  sf_tui_transport_next "${SF_PRESENT_RUNTIME:-null}" || transport_status=$?
  case $transport_status in
    0)
      if sf_tui_decoded "${reply[@]}"; then
        return 0
      fi
      ;;
    1) return 0 ;;
  esac
  # The live transcript cannot be trusted past a record the client could not
  # apply, and only the durable session can replace it.
  sf_tui_transport_stop
  sf_tui_discard_queue
  sf_tui_stop 'exec sent invalid JSONL'
  return 0
}

sf_tui_exec_finish() {
  local heading detail exit_detail
  integer exit_status cancelled=0 turn_error=$SF_PRESENT_TURN_ERROR
  sf_tui_transport_result || return 1
  exit_status=$reply[1]
  exit_detail=$reply[2]
  SF_PRESENT_TURN_ERROR=0
  if [[ -z $SF_PRESENT_SESSION ]] && (( ! exit_status )); then
    exit_status=1
    exit_detail='Create did not confirm session creation.'
  fi
  [[ $SF_PRESENT_STATE != cancelling ]] || cancelled=1
  if (( exit_status || cancelled )); then
    if (( turn_error )); then
      # The transcript already ends with the durable failure.
      heading=''
    elif (( cancelled && ! exit_status )); then
      # A completed worker wins the cancellation race.
      heading=''
    elif (( cancelled )); then
      heading='Cancelled.'
      detail=$exit_detail
    elif (( exit_status >= 128 )); then
      heading='Exec process terminated.'
      detail=${exit_detail:-"Terminated by signal $(( exit_status - 128 ))."}
    else
      if [[ -z $SF_PRESENT_SESSION ]]; then
        heading='Session creation failed.'
      else
        heading='Exec process failed.'
      fi
      detail=${exit_detail:-"Exited with status $exit_status."}
    fi
    sf_tui_discard_queue
    if [[ -n $REPLY ]]; then
      if [[ -z $heading ]]; then
        heading=$REPLY
      else
        [[ -z $detail ]] || detail+=$'\n'
        detail+=$REPLY
      fi
    fi
    if [[ -z $SF_PRESENT_SESSION ]]; then
      # Creation left no session, so there is nothing to continue from.
      sf_tui_stop "$heading" "$detail"
      return 0
    fi
    sf_tui_transport_reset
    sf_tui_permission_reset
    sf_tui_editor_permission discard
    SF_PRESENT_STATE=idle
    [[ -z $heading ]] || sf_tui_event error "$heading" "$detail" || return 1
  else
    sf_tui_event activity_stop || return 1
    SF_PRESENT_STATE=idle
    sf_tui_permission_reset
    if (( ${#SF_PRESENT_HANDOFF} )); then
      sf_tui_discard_queue
      SF_PRESENT_ACTION=handoff
    elif (( ${#SF_PRESENT_QUEUE} )); then
      SF_PRESENT_SUBMITTED=$SF_PRESENT_QUEUE[1]
      SF_PRESENT_QUEUE=( "${(@)SF_PRESENT_QUEUE[2,-1]}" )
      if ! sf_tui_client_command "$SF_PRESENT_SUBMITTED"; then
        SF_PRESENT_STATE=queued
        sf_tui_event user "$SF_PRESENT_SUBMITTED" || return 1
      fi
    fi
  fi
}

sf_tui_exec_ready() {
  sf_tui_transport_read "$1" || return 1
  sf_tui_heartbeat_arm
}

sf_tui_turn() {
  local prompt=$1 input

  [[ $SF_PRESENT_STATE == idle ]] || return 1
  input=$(jq -cn --arg prompt "$prompt" \
    '{type:"user",content:[{type:"text",text:$prompt}]}') || return 1
  SF_PRESENT_HANDOFF=()
  SF_PRESENT_TURN_ERROR=0
  SF_PRESENT_ACTIVITY_FRAME=0
  SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[1]}
  SF_PRESENT_STATE=working
  sf_tui_event activity_start || { SF_PRESENT_STATE=idle; return 1; }
  if ! sf_tui_transport_start "$input" sf_tui_exec_ready; then
    SF_PRESENT_STATE=idle
    SF_PRESENT_ERROR=$SF_TUI_TRANSPORT_ERROR
    return 1
  fi
}

sf_tui_answer_permission() {
  local decision=$1
  [[ $SF_PRESENT_STATE == permission && $decision == (approve|deny) ]] || return 1
  if ! sf_tui_transport_reply "$SF_PRESENT_PERMISSION_ID" "$decision"; then
    # The turn is waiting on a decision this client can no longer deliver.
    sf_tui_transport_stop
    sf_tui_editor_permission restore
    sf_tui_permission_reset
    sf_tui_stop 'cannot answer permission'
    return 1
  fi
  sf_tui_permission_reset
  sf_tui_event tool_permission_clear || return 1
  sf_tui_editor_permission restore
  SF_PRESENT_STATE=working
}

sf_tui_controller() {
  local session=$1 presentation=${2:-\{\}} initial=${3-}
  local session_mode=${4:-resume} draft=${5-}
  local input=$draft saved_tty editor_error system
  integer exit_status=0 editor_status=0

  SF_PRESENT_SESSION=$session
  SF_PRESENT_STATE=idle
  SF_PRESENT_ACTION=''
  SF_PRESENT_SUBMITTED=''
  SF_PRESENT_QUEUE=()
  SF_PRESENT_EXIT_STATUS=0
  sf_tui_terminal_reset
  zmodload zsh/zle || { SF_PRESENT_ERROR='cannot load ZLE'; return 1; }
  bindkey -e
  sf_tui_bind
  if [[ $session_mode == startup ]]; then
    SF_PRESENT_STATE=working
    sf_tui_transport_start '' sf_tui_exec_ready || {
      SF_PRESENT_ERROR=$SF_TUI_TRANSPORT_ERROR
      return 1
    }
    sf_tui_transport_read "$SF_TUI_TRANSPORT_OUTPUT_FD" || return 1
    if ! sf_tui_transport_next null || [[ $reply[1] != session_prepare ]]; then
      SF_PRESENT_ERROR=${SF_TUI_TRANSPORT_EXIT_DETAIL:-'Create did not prepare a session.'}
      return 1
    fi
    system=$reply[3]
    sf_tui_reset
    sf_tui_session_update "$reply[2]"
    [[ -z $system ]] || sf_tui_event system "$system" || return 1
    # Creation presents as a running turn, so hook activity and the spinner
    # land in the formatters a turn would use.
    sf_tui_event activity_start || return 1
  else
    sf_tui_reload "$session" || return 1
  fi
  sf_tui_rows_config "$presentation" || {
    SF_PRESENT_ERROR='cannot read presentation configuration'
    return 1
  }
  sf_tui_theme_config "$presentation" || {
    SF_PRESENT_ERROR=$SF_PRESENT_HIGHLIGHT_ERROR
    return 1
  }
  sf_tui_chat_start "$session_mode" "$session" || {
    SF_PRESENT_ERROR='cannot render startup banner'
    return 1
  }
  PROMPT=''
  saved_tty=$(stty -g 2>/dev/null) || return 1
  SF_PRESENT_TTY=$saved_tty
  if [[ -n $initial ]]; then
    sf_tui_record_prompt "$initial"
    if [[ $SF_PRESENT_STATE == working ]]; then
      SF_PRESENT_QUEUE=( "$initial" )
    else
      sf_tui_event user "$initial" || return 1
      sf_tui_turn "$initial" || return 1
    fi
  fi

  while (( ! exit_status )); do
    [[ $SF_PRESENT_ACTION == epoch ]] || SF_PRESENT_ACTION=''
    stty intr undef 2>/dev/null || { exit_status=1; break; }
    {
      if vared -h -M sf-present -p "$PROMPT" input; then
        editor_status=0
      else
        editor_status=$?
      fi
    } always { stty "$saved_tty" 2>/dev/null || true }
    [[ $SF_PRESENT_ACTION == epoch ]] || input=''
    case $SF_PRESENT_ACTION in
      epoch) SF_PRESENT_ACTION='' ;;
      submit)
        SF_PRESENT_STATE=idle
        sf_tui_turn "$SF_PRESENT_SUBMITTED" || exit_status=1
        ;;
      handoff|quit) break ;;
      *)
        editor_error="Chat editor exited unexpectedly (status $editor_status, state $SF_PRESENT_STATE)."
        [[ -z $SF_PRESENT_ERROR ]] || editor_error="$SF_PRESENT_ERROR"$'\n'"$editor_error"
        SF_PRESENT_ERROR=$editor_error
        exit_status=1
        ;;
    esac
  done
  sf_tui_heartbeat_stop
  sf_tui_terminal_sync_end force
  [[ $SF_PRESENT_STATE == idle ]] || sf_tui_transport_stop
  print
  if [[ $SF_PRESENT_ACTION == handoff ]]; then
    exec -- "${SF_PRESENT_HANDOFF[@]}"
    SF_PRESENT_ERROR='cannot execute handoff'
    return 1
  fi
  if [[ $SF_PRESENT_ACTION == quit ]]; then
    [[ -z $SF_PRESENT_SESSION ]] || sf_tui_chat_end "$SF_PRESENT_SESSION"
    return $SF_PRESENT_EXIT_STATUS
  fi
  (( exit_status )) || sf_tui_chat_end "$SF_PRESENT_SESSION"
  return $exit_status
}
