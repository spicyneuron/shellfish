emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -ga SF_PRESENT_HANDOFF=() SF_PRESENT_QUEUE=()
typeset -g SF_PRESENT_SESSION='' SF_PRESENT_RUNTIME='null'
typeset -g SF_PRESENT_ACTION='' SF_PRESENT_SUBMITTED=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_PERMISSION_ID=''
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -g SF_PRESENT_PERMISSION_LANGUAGE=''
typeset -gi SF_PRESENT_PERMISSION_PREVIEW_LENGTH=0
typeset -gi SF_PRESENT_EXIT_STATUS=0 SF_PRESENT_EXIT_PENDING=0
typeset -g SF_PRESENT_REASONING_TOKENS=''
typeset -g SF_PRESENT_IDENTITY='' SF_PRESENT_FOOTER=''

sf_chat_permission_reset() {
  SF_PRESENT_PERMISSION_ID=''
  SF_PRESENT_PERMISSION_TOOL=''
  SF_PRESENT_PERMISSION_TEXT=''
  SF_PRESENT_PERMISSION_LANGUAGE=''
  SF_PRESENT_PERMISSION_PREVIEW_LENGTH=0
}

TRAPTERM() {
  sf_chat_terminal_sync_end force
  [[ $SF_PRESENT_STATE == idle ]] || sf_chat_transport_stop
  exit 143
}

sf_chat_discard_queue() {
  integer count=${#SF_PRESENT_QUEUE}
  SF_PRESENT_QUEUE=()
  REPLY=''
  (( count )) || return 0
  REPLY="Discarded $count queued prompt"
  (( count == 1 )) || REPLY+='s'
  REPLY+='. Use ↑↓ keys to recover.'
}

sf_chat_submit() {
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
    sf_chat_record_prompt "$submitted"
    REPLY=repaint
    return
  fi
  [[ $SF_PRESENT_STATE == idle && -n $submitted ]] || return 0
  if [[ $submitted == (/quit|/q) ]]; then
    SF_PRESENT_ACTION=quit
    REPLY=quit
    return
  fi
  SF_PRESENT_SUBMITTED=$submitted
  sf_chat_record_prompt "$submitted"
  sf_chat_event user "$submitted" || return 1
  REPLY=submit
}

sf_chat_cancel() {
  local queue_notice
  REPLY=redraw
  case $SF_PRESENT_STATE in
    queued) return ;;
    cancelling)
      SF_PRESENT_EXIT_STATUS=130
      SF_PRESENT_EXIT_PENDING=1
      return
      ;;
    permission)
      sf_chat_editor_permission restore
      SF_PRESENT_STATE=cancelling
      sf_chat_transport_signal
      return
      ;;
    working)
      sf_chat_discard_queue
      queue_notice=$REPLY
      SF_PRESENT_STATE=cancelling
      sf_chat_transport_stop
      if sf_chat_recover 'Cancelled.' "$queue_notice"; then
        SF_PRESENT_STATE=idle
      else
        SF_PRESENT_STATE=stopped
      fi
      REPLY=reset
      return
      ;;
    idle|stopped)
      SF_PRESENT_EXIT_STATUS=130
      SF_PRESENT_ACTION=quit
      REPLY=quit
      ;;
  esac
}

sf_chat_notice() {
  local severity=$1 heading=$2 body=${3-}
  integer index=${#SF_PRESENT_NODE_TYPE} resume_tool=0
  if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
    if [[ $SF_PRESENT_NODE_TYPE[index] == tool_result ]]; then
      if [[ $severity == error ]]; then
        sf_chat_event tool_segment_close abandon || return 1
      else
        sf_chat_event tool_segment_close continue || return 1
        resume_tool=1
      fi
    else
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_chat_close $index || return 1
    fi
  fi
  sf_chat_add notice "$severity" "$heading" "$body" || return 1
  (( ! resume_tool )) || sf_chat_tool_open
}

sf_chat_decoded() {
  local type=$1 first=${2-} second=${3-} third=${4-} fourth=${5-} fifth=${6-} encoded preview reason
  case $type in
      backend_request_start|assistant_delta|assistant_reasoning_delta|tool_call|tool_result|context)
        sf_chat_event "$type" "$first" "$second" "$third" "$fourth" "$fifth" || return 1
        ;;
      assistant_commit)
        [[ -z $SF_PRESENT_REASONING_TOKENS ]] ||
          sf_chat_event reasoning_tokens "$SF_PRESENT_REASONING_TOKENS" || return 1
        sf_chat_event assistant_commit || return 1
        ;;
      turn_usage)
        SF_PRESENT_REASONING_TOKENS=$second
        SF_PRESENT_FOOTER="${SF_PRESENT_IDENTITY} · $first"
        [[ -z $second ]] || sf_chat_event reasoning_tokens "$second" || return 1
        ;;
      exec_error)
        sf_chat_notice error "$first" "$second" || return 1
        ;;
      hook_display)
        sf_chat_notice notice "$first: $second" "$third" || return 1
        ;;
      permission_request)
        [[ $SF_PRESENT_STATE == working && -z $SF_PRESENT_PERMISSION_ID ]] || return 1
        SF_PRESENT_PERMISSION_ID=$first
        sf_chat_safe "$second"
        SF_PRESENT_PERMISSION_TOOL=$REPLY
        sf_chat_safe "$third"
        preview=$REPLY
        sf_chat_safe "$fourth"
        reason=$REPLY
        SF_PRESENT_PERMISSION_TEXT="$preview"$'\n\nReason: '"$reason"
        SF_PRESENT_PERMISSION_LANGUAGE=$fifth
        SF_PRESENT_PERMISSION_PREVIEW_LENGTH=${#preview}
        sf_chat_editor_permission open
        SF_PRESENT_STATE=permission
        sf_chat_event tool_permission || return 1
        if (( ! REPLY )); then
          sf_chat_notice notice "Permission: $second" "$SF_PRESENT_PERMISSION_TEXT" || return 1
        fi
        ;;
      handoff)
        (( ! ${#SF_PRESENT_HANDOFF} )) || return 1
        encoded=$(jq -j '.[] | ., "\u0000"' <<<"$first") || return 1
        SF_PRESENT_HANDOFF=( "${(@0)${encoded%$'\0'}}" )
        ;;
      *) return 1 ;;
  esac
}

sf_chat_recover() {
  local heading=$1 detail=${2-}
  local type role node_heading body meta state cursor=$SF_PRESENT_CURSOR
  integer visible=$SF_PRESENT_PREFIX_VISIBLE index match=0
  sf_chat_transport_reset
  sf_chat_permission_reset
  sf_chat_editor_permission discard
  if (( visible && ${#SF_PRESENT_NODE_TYPE} )); then
    type=$SF_PRESENT_NODE_TYPE[1]
    role=$SF_PRESENT_NODE_ROLE[1]
    node_heading=$SF_PRESENT_NODE_HEADING[1]
    body=$SF_PRESENT_NODE_BODY[1]
    meta=$SF_PRESENT_NODE_META[1]
    state=$SF_PRESENT_NODE_STATE[1]
  fi
  sf_chat_reload "$SF_PRESENT_SESSION" || return 1
  if (( visible )); then
    if [[ -z $type ]]; then
      sf_chat_reset
    else
      for (( index = 1; index <= ${#SF_PRESENT_NODE_TYPE}; index++ )); do
        if [[ $SF_PRESENT_NODE_TYPE[index] == $type &&
            $SF_PRESENT_NODE_ROLE[index] == $role &&
            $SF_PRESENT_NODE_HEADING[index] == $node_heading &&
            $SF_PRESENT_NODE_BODY[index] == $body &&
            $SF_PRESENT_NODE_META[index] == $meta ]]; then
          match=$index
          break
        fi
      done
      if (( match )); then
        sf_chat_drop $(( match - 1 )) || return 1
      elif [[ $state == open ]]; then
        sf_chat_reset
      else
        SF_PRESENT_ERROR='cannot reconcile presentation with flushed scrollback'
        return 1
      fi
    fi
    SF_PRESENT_CURSOR=$cursor
  fi
  sf_chat_notice error "$heading" "$detail"
}

# Apply one transport record. The heartbeat drains the decoded batch only after
# rows from previously applied records have stopped flushing.
sf_chat_pending_next() {
  local queue_notice
  integer transport_status=0

  sf_chat_transport_next "${SF_PRESENT_RUNTIME:-null}" || transport_status=$?
  case $transport_status in
    0)
      sf_chat_decoded "${reply[@]}" && return 0
      ;;
    1) return 0 ;;
  esac
  sf_chat_transport_stop
  sf_chat_discard_queue
  queue_notice=$REPLY
  if sf_chat_recover 'Exec sent invalid JSONL.' "$queue_notice"; then
    SF_PRESENT_STATE=idle
  else
    SF_PRESENT_STATE=stopped
  fi
  return 0
}

sf_chat_exec_finish() {
  local heading detail
  integer exit_status
  sf_chat_transport_result || return 1
  exit_status=$reply[1]
  detail=$reply[2]
  if (( exit_status )); then
    heading=$([[ $SF_PRESENT_STATE == cancelling ]] && print 'Cancelled.' || print 'Exec exited unexpectedly.')
    sf_chat_discard_queue
    [[ -z $REPLY ]] || detail+="${detail:+$'\n'}$REPLY"
    if sf_chat_recover "$heading" "$detail"; then
      SF_PRESENT_STATE=idle
    else
      SF_PRESENT_STATE=stopped
    fi
  else
    if (( ${#SF_PRESENT_NODE_TYPE} )) && [[ $SF_PRESENT_NODE_TYPE[-1] == activity &&
        $SF_PRESENT_NODE_STATE[-1] == open ]]; then
      sf_chat_event assistant_commit || return 1
    fi
    SF_PRESENT_STATE=idle
    sf_chat_permission_reset
    if (( ${#SF_PRESENT_HANDOFF} )); then
      sf_chat_discard_queue
      SF_PRESENT_ACTION=handoff
    elif (( ${#SF_PRESENT_QUEUE} )); then
      SF_PRESENT_SUBMITTED=$SF_PRESENT_QUEUE[1]
      SF_PRESENT_QUEUE=( "${(@)SF_PRESENT_QUEUE[2,-1]}" )
      SF_PRESENT_STATE=queued
      sf_chat_event user "$SF_PRESENT_SUBMITTED" || return 1
    fi
  fi
}

sf_chat_exec_ready() {
  sf_chat_transport_read "$1" || return 1
  sf_chat_heartbeat_arm
}

sf_chat_turn() {
  local prompt=$1 input

  [[ $SF_PRESENT_STATE == idle ]] || return 1
  input=$(jq -cn --arg prompt "$prompt" \
    '{type:"message",role:"user",content:[{type:"text",text:$prompt}]}') || return 1
  SF_PRESENT_HANDOFF=()
  SF_PRESENT_REASONING_TOKENS=''
  SF_PRESENT_HEARTBEAT_REMAINING=0
  SF_PRESENT_ACTIVITY_FRAME=0
  SF_PRESENT_ACTIVITY_TICKS=0
  SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[1]}
  SF_PRESENT_STATE=working
  sf_chat_add activity '' '' '' open || { SF_PRESENT_STATE=idle; return 1; }
  if ! sf_chat_transport_start "$input" sf_chat_exec_ready; then
    sf_chat_reload "$SF_PRESENT_SESSION" || true
    SF_PRESENT_STATE=idle
    SF_PRESENT_ERROR=$SF_CHAT_TRANSPORT_ERROR
    return 1
  fi
}

sf_chat_answer_permission() {
  local decision=$1
  [[ $SF_PRESENT_STATE == permission && $decision == (approve|deny) ]] || return 1
  if ! sf_chat_transport_reply "$SF_PRESENT_PERMISSION_ID" "$decision"; then
    sf_chat_transport_stop
    sf_chat_editor_permission restore
    if sf_chat_recover 'Cannot answer permission.'; then
      SF_PRESENT_STATE=idle
    else
      SF_PRESENT_STATE=stopped
    fi
    return 1
  fi
  sf_chat_permission_reset
  sf_chat_event tool_permission_clear || return 1
  sf_chat_editor_permission restore
  SF_PRESENT_STATE=working
}

sf_chat_controller() {
  local session=$1 runtime=$2 initial=${3-} session_mode=${4:-resume} input saved_tty identity
  integer exit_status=0

  SF_PRESENT_SESSION=$session
  SF_PRESENT_RUNTIME=$runtime
  SF_PRESENT_STATE=idle
  SF_PRESENT_ACTION=''
  SF_PRESENT_SUBMITTED=''
  SF_PRESENT_QUEUE=()
  SF_PRESENT_EXIT_STATUS=0
  SF_PRESENT_EXIT_PENDING=0
  sf_chat_rows_config "${SF_PRESENTATION:-\{\}}" || {
    SF_PRESENT_ERROR='cannot read presentation configuration'
    return 1
  }
  sf_chat_theme_config "${SF_PRESENTATION:-\{\}}" || {
    SF_PRESENT_ERROR=$SF_PRESENT_HIGHLIGHT_ERROR
    return 1
  }
  sf_chat_terminal_reset
  sf_chat_reload "$session" || return 1
  identity=$(jq -r '.backend.name + "/" + .profile.request.model' <<<"$runtime" 2>/dev/null) || {
    SF_PRESENT_ERROR='cannot read session identity'
    return 1
  }
  SF_PRESENT_IDENTITY=$identity
  SF_PRESENT_FOOTER=$identity
  sf_chat_chat_start "$session_mode" "$session" || {
    SF_PRESENT_ERROR='cannot render startup banner'
    return 1
  }
  zmodload zsh/zle || { SF_PRESENT_ERROR='cannot load ZLE'; return 1; }
  bindkey -e
  sf_chat_bind
  PROMPT=''
  saved_tty=$(stty -g 2>/dev/null) || return 1
  if [[ -n $initial ]]; then
    sf_chat_record_prompt "$initial"
    sf_chat_event user "$initial" || return 1
    sf_chat_turn "$initial" || return 1
  fi

  while (( ! exit_status )); do
    input=''
    [[ $SF_PRESENT_ACTION == epoch ]] || SF_PRESENT_ACTION=''
    stty intr undef 2>/dev/null || { exit_status=1; break; }
    { vared -h -M sf-present -p "$PROMPT" input } always { stty "$saved_tty" 2>/dev/null || true }
    case $SF_PRESENT_ACTION in
      epoch) SF_PRESENT_ACTION='' ;;
      submit)
        SF_PRESENT_STATE=idle
        sf_chat_turn "$SF_PRESENT_SUBMITTED" || exit_status=1
        ;;
      handoff|quit) break ;;
      *) break ;;
    esac
  done
  sf_chat_terminal_sync_end force
  [[ $SF_PRESENT_STATE == idle ]] || sf_chat_transport_stop
  print
  if [[ $SF_PRESENT_ACTION == handoff ]]; then
    exec -- "${SF_PRESENT_HANDOFF[@]}"
    SF_PRESENT_ERROR='cannot execute handoff'
    return 1
  fi
  if [[ $SF_PRESENT_ACTION == quit ]]; then
    sf_chat_chat_end "$session"
    return $SF_PRESENT_EXIT_STATUS
  fi
  (( exit_status )) || sf_chat_chat_end "$session"
  return $exit_status
}
