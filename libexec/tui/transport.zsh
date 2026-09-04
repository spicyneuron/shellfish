emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_scratch_file] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -ga SF_TUI_TRANSPORT_COMMAND=() SF_TUI_TRANSPORT_LINES=()
typeset -ga SF_TUI_TRANSPORT_EVENTS=()
typeset -g SF_TUI_TRANSPORT_PID='' SF_TUI_TRANSPORT_INPUT_FD=''
typeset -g SF_TUI_TRANSPORT_OUTPUT_FD='' SF_TUI_TRANSPORT_ERROR_FILE=''
typeset -gi SF_TUI_TRANSPORT_EOF=0 SF_TUI_TRANSPORT_EXIT_STATUS=0
typeset -g SF_TUI_TRANSPORT_EXIT_DETAIL='' SF_TUI_TRANSPORT_ERROR=''

sf_tui_transport_reset() {
  SF_TUI_TRANSPORT_LINES=()
  SF_TUI_TRANSPORT_EVENTS=()
  SF_TUI_TRANSPORT_EOF=0
  SF_TUI_TRANSPORT_EXIT_STATUS=0
  SF_TUI_TRANSPORT_EXIT_DETAIL=''
  SF_TUI_TRANSPORT_ERROR=''
}

sf_tui_transport_has_pending() {
  # A type filter matches only the head of an already decoded batch.
  if (( $# )); then
    (( $# == 1 && ${#SF_TUI_TRANSPORT_EVENTS} >= 7 )) || return 1
    [[ $SF_TUI_TRANSPORT_EVENTS[1] == $1 ]]
    return
  fi
  (( ${#SF_TUI_TRANSPORT_EVENTS} || ${#SF_TUI_TRANSPORT_LINES} ))
}

sf_tui_transport_is_complete() {
  (( SF_TUI_TRANSPORT_EOF ))
}

sf_tui_transport_watch() {
  local callback=$1
  [[ -n $callback ]] || return 1
  [[ -n $SF_TUI_TRANSPORT_OUTPUT_FD ]] || return 0
  zle -F -w "$SF_TUI_TRANSPORT_OUTPUT_FD" "$callback"
}

sf_tui_transport_unwatch() {
  [[ -z $SF_TUI_TRANSPORT_OUTPUT_FD ]] ||
    zle -F "$SF_TUI_TRANSPORT_OUTPUT_FD" 2>/dev/null || true
}

sf_tui_transport_close() {
  local pid=$SF_TUI_TRANSPORT_PID error_file=$SF_TUI_TRANSPORT_ERROR_FILE detail=''
  integer exit_status=0

  sf_tui_transport_unwatch
  [[ -z $SF_TUI_TRANSPORT_INPUT_FD ]] || exec {SF_TUI_TRANSPORT_INPUT_FD}>&-
  [[ -z $SF_TUI_TRANSPORT_OUTPUT_FD ]] || exec {SF_TUI_TRANSPORT_OUTPUT_FD}<&-
  SF_TUI_TRANSPORT_INPUT_FD=''
  SF_TUI_TRANSPORT_OUTPUT_FD=''
  SF_TUI_TRANSPORT_PID=''
  [[ -z $pid ]] || wait "$pid" 2>/dev/null || exit_status=$?
  if [[ -n $error_file ]]; then
    [[ ! -s $error_file ]] ||
      detail=$(LC_ALL=C tr -s '[:cntrl:]' ' ' <"$error_file" | cut -c 1-1000)
    rm -f -- "$error_file"
  fi
  SF_TUI_TRANSPORT_ERROR_FILE=''
  SF_TUI_TRANSPORT_EXIT_STATUS=$exit_status
  SF_TUI_TRANSPORT_EXIT_DETAIL=$detail
  return $exit_status
}

sf_tui_transport_signal() {
  if [[ -n $SF_TUI_TRANSPORT_PID ]]; then
    kill -TERM -- "-$SF_TUI_TRANSPORT_PID" 2>/dev/null ||
      kill -TERM "$SF_TUI_TRANSPORT_PID" 2>/dev/null || true
    kill -CONT -- "-$SF_TUI_TRANSPORT_PID" 2>/dev/null ||
      kill -CONT "$SF_TUI_TRANSPORT_PID" 2>/dev/null || true
  fi
}

sf_tui_transport_stop() {
  sf_tui_transport_signal
  sf_tui_transport_close || true
}

sf_tui_transport_start() {
  local input=$1 callback=$2 error_file pid
  integer had_monitor=$options[monitor] had_bg_nice=$options[bg_nice]

  [[ -z $SF_TUI_TRANSPORT_PID ]] || {
    SF_TUI_TRANSPORT_ERROR='exec process is already running'
    return 1
  }
  (( ${#SF_TUI_TRANSPORT_COMMAND} )) || {
    SF_TUI_TRANSPORT_ERROR='exec command is not configured'
    return 1
  }
  sf_tui_transport_reset
  sf_scratch_file transport exec-error || {
    SF_TUI_TRANSPORT_ERROR='cannot create exec error file'
    return 1
  }
  error_file=$REPLY
  SF_TUI_TRANSPORT_ERROR_FILE=$error_file
  unsetopt monitor bg_nice
  coproc "${SF_TUI_TRANSPORT_COMMAND[@]}" 2>"$error_file"
  pid=$!
  SF_TUI_TRANSPORT_PID=$pid
  if ! exec {SF_TUI_TRANSPORT_INPUT_FD}>&p ||
      ! exec {SF_TUI_TRANSPORT_OUTPUT_FD}<&p; then
    (( ! had_monitor )) || setopt monitor
    (( ! had_bg_nice )) || setopt bg_nice
    sf_tui_transport_stop
    SF_TUI_TRANSPORT_ERROR='cannot attach to exec process'
    return 1
  fi
  coproc :
  (( ! had_monitor )) || setopt monitor
  (( ! had_bg_nice )) || setopt bg_nice
  # A fast exec exit must turn a broken initial pipe into a startup error.
  if ! (
    trap '' PIPE
    print -r -- "$input" >&$SF_TUI_TRANSPORT_INPUT_FD 2>/dev/null
  ); then
    sf_tui_transport_stop
    SF_TUI_TRANSPORT_ERROR='cannot write to exec process'
    return 1
  fi
  if ! sf_tui_transport_watch "$callback"; then
    sf_tui_transport_stop
    SF_TUI_TRANSPORT_ERROR='cannot watch exec process'
    return 1
  fi
}

sf_tui_transport_read() {
  local fd=$1 line
  integer received=0

  [[ -n $SF_TUI_TRANSPORT_OUTPUT_FD && $fd == $SF_TUI_TRANSPORT_OUTPUT_FD ]] || return 1
  if IFS= read -r -u "$fd" line; then
    SF_TUI_TRANSPORT_LINES+=( "$line" )
    received=1
    while IFS= read -r -t 0 -u "$fd" line; do
      SF_TUI_TRANSPORT_LINES+=( "$line" )
    done
  fi
  if (( ! received )); then
    sf_tui_transport_close || true
    SF_TUI_TRANSPORT_EOF=1
  fi
}

# Returns 0 with one event in reply, 1 when empty, and 2 for malformed output.
sf_tui_transport_next() {
  local runtime=${1:-null} events
  local -a decoded fields
  integer complete=0 index

  if (( ! ${#SF_TUI_TRANSPORT_EVENTS} )); then
    (( ${#SF_TUI_TRANSPORT_LINES} )) || return 1
    events=$(printf '%s\n' "${SF_TUI_TRANSPORT_LINES[@]}" |
      jq -jRs -L "$SF_ROOT" --argjson runtime "$runtime" \
        -f "$SF_ROOT/libexec/tui/event-decode.jq" 2>/dev/null) || events=''
    SF_TUI_TRANSPORT_LINES=()
    fields=( "${(@0)${events%$'\0'}}" )
    for (( index = 1; index + 6 <= ${#fields}; index += 7 )); do
      if [[ $fields[index] == batch_ok ]]; then
        complete=1
      else
        decoded+=( "${(@)fields[index,index + 6]}" )
      fi
    done
    (( complete )) || return 2
    SF_TUI_TRANSPORT_EVENTS+=( "${decoded[@]}" )
    (( ${#SF_TUI_TRANSPORT_EVENTS} )) || return 1
  fi
  reply=( "${(@)SF_TUI_TRANSPORT_EVENTS[1,7]}" )
  SF_TUI_TRANSPORT_EVENTS=( "${(@)SF_TUI_TRANSPORT_EVENTS[8,-1]}" )
}

sf_tui_transport_result() {
  (( SF_TUI_TRANSPORT_EOF )) || return 1
  reply=( "$SF_TUI_TRANSPORT_EXIT_STATUS" "$SF_TUI_TRANSPORT_EXIT_DETAIL" )
  SF_TUI_TRANSPORT_EOF=0
  SF_TUI_TRANSPORT_EXIT_STATUS=0
  SF_TUI_TRANSPORT_EXIT_DETAIL=''
}

sf_tui_transport_reply() {
  local id=$1 decision=$2
  [[ -n $id && $decision == (approve|deny) && -n $SF_TUI_TRANSPORT_INPUT_FD ]] || return 1
  jq -cn --arg id "$id" --arg decision "$decision" \
    '{type:"_tool_permission_response",id:$id,decision:$decision}' \
    >&$SF_TUI_TRANSPORT_INPUT_FD
}
