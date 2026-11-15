emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/profile.zsh"

typeset -ga SF_TUI_HANDOFF=() SF_TUI_QUEUE=()
typeset -g SF_TUI_SESSION='' SF_TUI_CWD=$PWD
typeset -g SF_TUI_ACTION='' SF_TUI_SUBMITTED=''
typeset -g SF_TUI_STATE=idle SF_TUI_PERMISSION_ID=''
typeset -g SF_TUI_PERMISSION_TOOL='' SF_TUI_PERMISSION_TEXT=''
# Listed access may be approved for the session; a bypass only once.
typeset -g SF_TUI_PERMISSION_KIND=''
typeset -g SF_TUI_PERMISSION_REVIEW=''
# The choice that applies when the deadline passes.
typeset -g SF_TUI_PERMISSION_DEFAULT=''
typeset -gi SF_TUI_PERMISSION_DEADLINE=0
typeset -gi SF_TUI_EXIT_STATUS=0
typeset -gi SF_TUI_ERROR_SETTLED=0
typeset -gi SF_TUI_CREATING=0 SF_TUI_STEER=0
typeset -g SF_TUI_TTY=''
# Client command names and aliases, also completed. /queue runs in sf_tui_submit.
typeset -grA SF_TUI_CLIENT_COMMANDS=(
  /quit /quit /q /quit /refresh /refresh /r /refresh /queue /queue )
typeset -ga SF_TUI_COMMANDS=( ${(ovu)SF_TUI_CLIENT_COMMANDS} )

# Arguments are the session header's stored command paths.
sf_tui_commands() {
  local reference profile names
  local -a directories=()
  SF_TUI_COMPLETIONS=()
  SF_TUI_COMMANDS=( ${(ovu)SF_TUI_CLIENT_COMMANDS} )
  for reference in "$@"; do
    sf_cli_path "$reference" || return 0
    directories+=( "$REPLY" )
  done
  profile=$(jq -cn --args '{tools:[],hooks:[],commands:$ARGS.positional}' \
    "${directories[@]}") || return 0
  sf_profile_components "$profile" || return 0
  names=$(jq -r '.commands[] | .name, (.manifest.aliases[]? | select(length > 1))' \
    <<<"$REPLY") || return 0
  [[ -z $names ]] || SF_TUI_COMMANDS+=( ${${(f)names}/#//} )
  SF_TUI_COMMANDS=( ${(ou)SF_TUI_COMMANDS} )
}

sf_tui_permission_reset() {
  SF_TUI_PERMISSION_ID=''
  SF_TUI_PERMISSION_TOOL=''
  SF_TUI_PERMISSION_TEXT=''
  SF_TUI_PERMISSION_KIND=''
  SF_TUI_PERMISSION_REVIEW=''
  SF_TUI_PERMISSION_DEFAULT=''
  SF_TUI_PERMISSION_DEADLINE=0
}

TRAPTERM() {
  sf_tui_terminal_sync_end force
  [[ $SF_TUI_STATE == idle ]] || sf_tui_transport_stop
  exit 143
}

sf_tui_discard_queue() {
  integer count=${#SF_TUI_QUEUE}
  SF_TUI_QUEUE=()
  REPLY=''
  (( count )) || return 0
  REPLY="Discarded $count queued prompt"
  (( count == 1 )) || REPLY+='s'
  REPLY+='. Use ↑↓ keys to recover.'
}

sf_tui_client_command() {
  case ${SF_TUI_CLIENT_COMMANDS[$1]-} in
    /quit)
      SF_TUI_ACTION=quit
      ;;
    /refresh)
      [[ -n $SF_TUI_SESSION ]] || return 1
      SF_TUI_HANDOFF=( "$SF_ENTRY" --clear --session "$SF_TUI_SESSION" )
      SF_TUI_ACTION=handoff
      ;;
    *) return 1 ;;
  esac
}

sf_tui_submit() {
  local submitted=$1
  integer queue_index
  REPLY=ignore
  if [[ $submitted =~ '^/queue[[:space:]]+clear[[:space:]]*$' ]]; then
    SF_TUI_QUEUE=()
    REPLY=repaint
    return
  fi
  if [[ $submitted =~ '^/queue[[:space:]]+drop[[:space:]]+([0-9]+)[[:space:]]*$' ]]; then
    queue_index=$match[1]
    (( queue_index >= 1 && queue_index <= ${#SF_TUI_QUEUE} )) || return 0
    SF_TUI_QUEUE[queue_index]=()
    REPLY=repaint
    return
  fi
  [[ $submitted != /queue([[:space:]]|$)* ]] || return 0
  if [[ $SF_TUI_STATE == (working|queued) ]]; then
    [[ -n $submitted ]] || return 0
    SF_TUI_QUEUE+=( "$submitted" )
    sf_tui_record_prompt "$submitted"
    REPLY=repaint
    return
  fi
  if [[ $SF_TUI_STATE == (idle|stopped) ]] && sf_tui_client_command "$submitted"; then
    REPLY=quit
    return
  fi
  [[ $SF_TUI_STATE == idle && -n $submitted ]] || return 0
  SF_TUI_SUBMITTED=$submitted
  sf_tui_record_prompt "$submitted"
  REPLY=submit
}

# Cancel the turn, then send the draft or the next queued prompt.
sf_tui_steer() {
  local draft=$BUFFER
  REPLY=redraw
  [[ $SF_TUI_STATE == (working|permission|cancelling) ]] || return 0
  [[ $SF_TUI_STATE != permission ]] || draft=$SF_TUI_PERMISSION_DRAFT
  [[ -n $draft ]] || (( ${#SF_TUI_QUEUE} )) || return 0
  [[ $SF_TUI_STATE == cancelling ]] || sf_tui_cancel
  if [[ -n $draft ]]; then
    SF_TUI_QUEUE[1,0]=( "$draft" )
    sf_tui_record_prompt "$draft"
    BUFFER=''
    CURSOR=0
  fi
  SF_TUI_STEER=1
}

sf_tui_cancel() {
  REPLY=redraw
  case $SF_TUI_STATE in
    queued) return ;;
    cancelling)
      SF_TUI_EXIT_STATUS=130
      SF_TUI_ACTION=quit
      REPLY=quit
      return
      ;;
    permission|working)
      [[ $SF_TUI_STATE != permission ]] || sf_tui_editor_permission restore
      SF_TUI_STATE=cancelling
      sf_tui_transport_cancel
      return
      ;;
    idle|stopped)
      SF_TUI_EXIT_STATUS=130
      SF_TUI_ACTION=quit
      REPLY=quit
      ;;
  esac
}

# Workflow actions stay here; everything else is presentation. A settled error
# ends the turn, so later activity makes it ordinary output again.
sf_tui_apply() {
  local type=$1 preview reason
  [[ $type == error ]] || SF_TUI_ERROR_SETTLED=0
  # Review activity does not close the prompt that is racing it.
  if [[ $SF_TUI_STATE == permission && ( $type == error ||
      ( $type == execution_(update|end) && $3 == tool ) ) ]]; then
    sf_tui_permission_close
  fi
  case $type in
    commands) sf_tui_commands "${@:2}" ;;
    cwd) ! sf_cli_path "$2" || SF_TUI_CWD=$REPLY ;;
    session)
      [[ -n $SF_TUI_SESSION ]] || SF_TUI_TRANSPORT_COMMAND=(
        "$SF_ENTRY" run --jsonl --session "$2" )
      SF_TUI_SESSION=$2
      ;;
    permission)
      [[ $SF_TUI_STATE == working && -z $SF_TUI_PERMISSION_ID ]] || return 1
      SF_TUI_PERMISSION_ID=$2
      SF_TUI_PERMISSION_DEFAULT=deny
      SF_TUI_PERMISSION_DEADLINE=$(( SECONDS + $6 ))
      sf_tui_safe "$3"
      SF_TUI_PERMISSION_TOOL=$REPLY
      sf_tui_safe "$4"
      preview=$REPLY
      sf_tui_safe "$5"
      reason=$REPLY
      SF_TUI_PERMISSION_TEXT="$preview"$'\nReason: '"$reason"
      SF_TUI_PERMISSION_KIND=$7
      [[ ${8-} != checking ]] || SF_TUI_PERMISSION_REVIEW='checking…'
      sf_tui_editor_permission open
      SF_TUI_STATE=permission
      sf_tui_activity_hold
      ;;
    permission_review)
      [[ $SF_TUI_STATE == permission && $2 == $SF_TUI_PERMISSION_ID ]] || return 0
      sf_tui_safe "$4"
      SF_TUI_PERMISSION_REVIEW="${3:-deferred}${REPLY:+: $REPLY}"
      ;;
    permission_update)
      [[ $SF_TUI_STATE == permission && $2 == $SF_TUI_PERMISSION_ID ]] || return 0
      SF_TUI_PERMISSION_DEFAULT=$3
      SF_TUI_PERMISSION_DEADLINE=$(( SECONDS + $4 ))
      ;;
    permission_end)
      [[ $SF_TUI_STATE != permission || $2 != $SF_TUI_PERMISSION_ID ]] ||
        sf_tui_permission_close
      ;;
    prompt) sf_tui_record_prompt "$2" ;;
    handoff)
      (( ! ${#SF_TUI_HANDOFF} )) || return 1
      SF_TUI_HANDOFF=( "${@:2}" )
      ;;
    error)
      sf_tui_action "$@" || return 1
      SF_TUI_ERROR_SETTLED=1
      ;;
    *) sf_tui_action "$@" || return 1 ;;
  esac
}

# Before a session exists, only creation activity may arrive.
sf_tui_drain_actions() {
  local record
  local -a fields
  integer applied=1
  for record in "${SF_TUI_ACTIONS[@]}"; do
    fields=( "${(@ps:\0:)record}" )
    if [[ -z $SF_TUI_SESSION &&
        $fields[1] != (session|execution_update|execution_end|error) ]] ||
        ! sf_tui_apply "${fields[@]}"; then
      applied=0
      break
    fi
  done
  SF_TUI_ACTIONS=()
  (( applied ))
}

sf_tui_pending_next() {
  local -a lines=( "${SF_TUI_TRANSPORT_LINES[@]}" )
  SF_TUI_TRANSPORT_LINES=()
  sf_tui_project "$SF_TUI_PROJECT_MODE" "${lines[@]}" &&
    sf_tui_drain_actions && return 0
  # Reloading is the only recovery from invalid live output.
  sf_tui_transport_stop
  sf_tui_discard_queue
  sf_tui_stop 'turn sent invalid JSONL'
  return 0
}

sf_tui_turn_finish() {
  local heading detail exit_detail
  integer exit_status cancelled=0 settled_error=$SF_TUI_ERROR_SETTLED
  integer creating=$SF_TUI_CREATING steer=$SF_TUI_STEER resumable
  sf_tui_transport_result || return 1
  exit_status=$reply[1]
  exit_detail=$reply[2]
  SF_TUI_ERROR_SETTLED=0
  SF_TUI_CREATING=0
  SF_TUI_STEER=0
  if (( creating && ! exit_status )) && [[ -z $SF_TUI_SESSION ]]; then
    exit_status=1
    exit_detail='Create exited without loading a session.'
  fi
  [[ $SF_TUI_STATE != cancelling ]] || cancelled=1
  # The queue survives only a cancellation the core settled itself.
  resumable=$(( cancelled && ! creating && (exit_status == 0 || exit_status == 130) ))
  [[ $SF_TUI_STATE != permission ]] || sf_tui_editor_permission restore
  sf_tui_activity_stop || return 1
  if (( exit_status || cancelled )); then
    if (( settled_error )); then
      heading=''
    elif (( cancelled && ! exit_status )); then
      heading=''
    elif (( cancelled )); then
      heading='Cancelled.'
      detail=$exit_detail
    elif (( exit_status >= 128 )); then
      heading='Turn terminated.'
      detail=${exit_detail:-"Terminated by signal $(( exit_status - 128 ))."}
    else
      if (( creating )); then
        heading='Session creation failed.'
      else
        heading='Turn failed.'
      fi
      detail=${exit_detail:-"Exited with status $exit_status."}
    fi
    REPLY=''
    (( resumable )) || sf_tui_discard_queue
    if [[ -n $REPLY ]]; then
      if [[ -z $heading ]]; then
        heading=$REPLY
      else
        [[ -z $detail ]] || detail+=$'\n'
        detail+=$REPLY
      fi
    fi
    # A creation path is provisional until its process succeeds.
    (( ! creating )) || SF_TUI_SESSION=''
    if [[ -z $SF_TUI_SESSION ]]; then
      sf_tui_stop "$heading" "$detail"
      return 0
    fi
    sf_tui_transport_reset
    sf_tui_permission_reset
    SF_TUI_STATE=idle
    [[ -z $heading ]] || sf_tui_action error "$heading" "$detail" || return 1
    (( ! resumable || ! steer )) || sf_tui_dequeue
  else
    SF_TUI_STATE=idle
    sf_tui_permission_reset
    if (( ${#SF_TUI_HANDOFF} )); then
      sf_tui_discard_queue
      SF_TUI_ACTION=handoff
    else
      sf_tui_dequeue
    fi
  fi
}

sf_tui_dequeue() {
  (( ${#SF_TUI_QUEUE} )) || return 0
  SF_TUI_SUBMITTED=$SF_TUI_QUEUE[1]
  SF_TUI_QUEUE=( "${(@)SF_TUI_QUEUE[2,-1]}" )
  sf_tui_client_command "$SF_TUI_SUBMITTED" || SF_TUI_STATE=queued
}

sf_tui_turn_ready() {
  sf_tui_transport_read "$1" || return 1
  sf_tui_heartbeat_arm
}

# Sets REPLY to a readable file's image format, read from its leading bytes.
sf_tui_image_format() {
  [[ -f $1 && -r $1 ]] || return 1
  case $(head -c 12 -- "$1" | od -An -tx1 | tr -d ' \n') in
    (89504e470d0a1a0a*) REPLY=png ;;
    (ffd8ff*) REPLY=jpeg ;;
    (47494638*) REPLY=gif ;;
    (52494646????????57454250) REPLY=webp ;;
    (*) return 1 ;;
  esac
}

# The prompt's user record, attaching each [Image: PATH] marker's image file.
# Images stream into jq, since one can exceed an argument's size limit.
sf_tui_user_record() {
  local rest=$1 file
  while [[ $rest == *'[Image: '*']'* ]]; do
    rest=${rest#*\[Image: } file=${rest%%\]*} rest=${rest#*\]}
    sf_tui_image_format "$file" || continue
    print -rn -- "data:image/$REPLY;base64,"
    base64 <"$file" | tr -d '\n'
    print
  done | jq -cRn --arg prompt "$1" '
    {type:"user",content:([{type:"text",text:$prompt}] + [inputs | {type:"image",url:.}])}'
}

sf_tui_turn() {
  local prompt=$1 input

  [[ $SF_TUI_STATE == idle ]] || return 1
  input=$(sf_tui_user_record "$prompt") || return 1
  SF_TUI_HANDOFF=()
  SF_TUI_ERROR_SETTLED=0
  SF_TUI_CREATING=0
  SF_TUI_STEER=0
  SF_TUI_ACTIVITY_FRAME=0
  SF_TUI_ACTIVITY=${SF_TUI_ACTIVITY_FRAMES[1]}
  SF_TUI_STATE=working
  SF_TUI_PROJECT_MODE=live
  sf_tui_activity_start || { SF_TUI_STATE=idle; return 1; }
  if ! sf_tui_transport_start "$input" sf_tui_turn_ready; then
    SF_TUI_STATE=idle
    SF_TUI_ERROR=$SF_TUI_TRANSPORT_ERROR
    return 1
  fi
}

# Send DECISION for the open request, stopping the turn if the reply fails.
sf_tui_permission_reply() {
  sf_tui_transport_reply "$SF_TUI_PERMISSION_ID" "$1" && return 0
  sf_tui_transport_stop
  sf_tui_editor_permission restore
  sf_tui_permission_reset
  sf_tui_stop 'cannot answer permission'
  return 1
}

sf_tui_answer_permission() {
  local decision=$1
  sf_tui_permission_choices
  [[ $SF_TUI_STATE == permission && $decision != stop ]] &&
    (( ${reply[(Ie)$decision]} )) || return 1
  sf_tui_permission_reply "$decision" || return 1
  sf_tui_permission_close
}

# Any other key takes control, and the core restarts the countdown on deny.
sf_tui_hold_permission() {
  sf_tui_permission_reply hold
}

sf_tui_permission_close() {
  sf_tui_permission_reset
  sf_tui_activity_start
  sf_tui_editor_permission restore
  SF_TUI_STATE=working
}

# Replay an existing session through the same projector as a live turn.
sf_tui_load() {
  local session=$1 line
  local -a loaded=()
  integer endings=0
  [[ -f $session && ! -L $session && -r $session && -s $session ]] || {
    SF_TUI_ERROR="cannot read session: $session"
    return 1
  }
  endings=$(tail -c 1 "$session" | wc -l) || endings=0
  (( endings == 1 )) || {
    SF_TUI_ERROR="cannot read incomplete session: $session"
    return 1
  }
  while IFS= read -r line; do loaded+=( "$line" ); done <"$session"
  sf_tui_reset
  sf_tui_project load "${loaded[@]}" && sf_tui_drain_actions || {
    SF_TUI_ERROR="cannot present session: $session"
    return 1
  }
}

sf_tui_controller() {
  local session=$1 presentation=${2:-\{\}} initial=${3-}
  local session_mode=${4:-resume} draft=${5-}
  local input=$draft saved_tty editor_error
  integer exit_status=0 editor_status=0

  SF_TUI_SESSION=$session
  SF_TUI_STATE=idle
  SF_TUI_ACTION=''
  SF_TUI_SUBMITTED=''
  SF_TUI_QUEUE=()
  SF_TUI_EXIT_STATUS=0
  SF_TUI_CREATING=0
  SF_TUI_STEER=0
  [[ $session_mode != startup ]] || SF_TUI_CREATING=1
  sf_tui_terminal_reset
  zmodload zsh/zle || { SF_TUI_ERROR='cannot load ZLE'; return 1; }
  bindkey -e
  sf_tui_bind
  # Configure presentation before any content arrives.
  sf_tui_rows_config "$presentation" || {
    SF_TUI_ERROR='cannot read presentation configuration'
    return 1
  }
  sf_tui_theme_config "$presentation" || {
    SF_TUI_ERROR=$SF_TUI_HIGHLIGHT_ERROR
    return 1
  }
  # Start creation before drawing anything; its hooks are the slow part.
  if [[ $session_mode == startup ]]; then
    SF_TUI_STATE=working
    sf_tui_activity_start || return 1
    sf_tui_transport_start '' sf_tui_turn_ready || {
      SF_TUI_ERROR=$SF_TUI_TRANSPORT_ERROR
      return 1
    }
  fi
  sf_tui_chat_start "$session_mode" "$session" || {
    SF_TUI_ERROR='cannot render startup banner'
    return 1
  }
  [[ $session_mode == startup ]] || sf_tui_load "$session" || return 1
  PROMPT=''
  saved_tty=$(stty -g 2>/dev/null) || return 1
  SF_TUI_TTY=$saved_tty
  if [[ -n $initial ]]; then
    sf_tui_record_prompt "$initial"
    if [[ $SF_TUI_STATE == working ]]; then
      SF_TUI_QUEUE=( "$initial" )
    else
      sf_tui_turn "$initial" || return 1
    fi
  fi

  while (( ! exit_status )); do
    [[ $SF_TUI_ACTION == epoch ]] || SF_TUI_ACTION=''
    stty intr undef 2>/dev/null || { exit_status=1; break; }
    {
      if vared -h -M sf-present -p "$PROMPT" input; then
        editor_status=0
      else
        editor_status=$?
      fi
    } always { stty "$saved_tty" 2>/dev/null || true }
    [[ $SF_TUI_ACTION == epoch ]] || input=''
    case $SF_TUI_ACTION in
      epoch) SF_TUI_ACTION='' ;;
      submit)
        SF_TUI_STATE=idle
        sf_tui_turn "$SF_TUI_SUBMITTED" || exit_status=1
        ;;
      handoff|quit) break ;;
      *)
        editor_error="Chat editor exited unexpectedly (status $editor_status, state $SF_TUI_STATE)."
        [[ -z $SF_TUI_ERROR ]] || editor_error="$SF_TUI_ERROR"$'\n'"$editor_error"
        SF_TUI_ERROR=$editor_error
        exit_status=1
        ;;
    esac
  done
  sf_tui_heartbeat_stop
  sf_tui_terminal_sync_end force
  [[ $SF_TUI_STATE == idle ]] || sf_tui_transport_stop
  print
  if [[ $SF_TUI_ACTION == handoff ]]; then
    exec -- "${SF_TUI_HANDOFF[@]}"
    SF_TUI_ERROR='cannot execute handoff'
    return 1
  fi
  if [[ $SF_TUI_ACTION == quit ]]; then
    [[ -z $SF_TUI_SESSION ]] || sf_tui_chat_end "$SF_TUI_SESSION"
    return $SF_TUI_EXIT_STATUS
  fi
  (( exit_status )) || sf_tui_chat_end "$SF_TUI_SESSION"
  return $exit_status
}
