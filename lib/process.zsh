emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

typeset -g SF_PROCESS_CAPTURE_PID=''
typeset -gi SF_PROCESS_CAPTURE_INTERRUPTED=0

# The control pipe is part of the capture contract: a sandboxed caller must
# expose this path before sf_process_capture creates it.
sf_process_control_pipe() {
  REPLY="$1/control.pipe"
}

sf_process_capture_stream() {
  local pipe=$1 output=$2 callback=$3 chunk notice=''
  integer limit=$4 fd event_fd callback_limit=$(( limit - 1 ))
  local LC_ALL=C

  exec {fd}<"$pipe" || return
  exec {event_fd}>&1 || { exec {fd}<&-; return 1; }
  {
    while sysread -i $fd -s 4096 chunk; do
      if [[ -n $callback ]]; then
        notice+=$chunk
        if [[ $notice == *$'\n'* ]]; then
          notice=${notice%%$'\n'*}$'\n'
          if (( ${#notice} <= callback_limit )); then
            "$callback" "$notice" >&$event_fd || return
          fi
          callback=''
        elif (( ${#notice} > callback_limit )); then
          callback=''
        fi
      fi
      print -rn -- "$chunk"
    done
  } | tail -c "$limit" >"$output"
  local -a statuses=( $pipestatus )
  exec {fd}<&-
  exec {event_fd}>&-
  (( statuses[1] == 0 && statuses[2] == 0 ))
}

# Captures one process while retaining at most one byte beyond the configured
# limit on each channel. The caller interprets the captured channels.
sf_process_capture() {
  local input=$1 directory=$2 working=$3 mode=$4 callback=$5
  integer max_capture=$6
  shift 6
  local stdout="$directory/stdout" stderr="$directory/stderr" control="$directory/control"
  local stdout_pipe="$stdout.pipe" stderr_pipe="$stderr.pipe" control_pipe REPLY
  local -a readers
  sf_process_control_pipe "$directory"
  control_pipe=$REPLY
  integer limit=$(( max_capture + 1 )) process_pid process_status reader_status=0 reader
  setopt local_options no_err_exit no_monitor
  SF_PROCESS_CAPTURE_INTERRUPTED=0

  rm -f -- "$stdout" "$stderr" "$control" \
    "$stdout_pipe" "$stderr_pipe" "$control_pipe"
  mkfifo "$stdout_pipe" "$control_pipe" || return 1
  if [[ $mode == separate ]]; then
    mkfifo "$stderr_pipe" || return 1
  elif [[ $mode == merged && -z $callback ]]; then
    : >"$stderr" || return 1
  else
    return 1
  fi

  sf_process_capture_stream "$stdout_pipe" "$stdout" '' $limit &
  readers+=( $! )
  sf_process_capture_stream "$control_pipe" "$control" '' $limit &
  readers+=( $! )
  if [[ $mode == separate ]]; then
    sf_process_capture_stream "$stderr_pipe" "$stderr" "$callback" $limit &
    readers+=( $! )
    coproc (cd -- "$working" && exec "$@") \
      <"$input" >"$stdout_pipe" 2>"$stderr_pipe" 3>"$control_pipe"
  else
    coproc (cd -- "$working" && exec "$@") \
      <"$input" >"$stdout_pipe" 2>&1 3>"$control_pipe"
  fi
  process_pid=$!
  SF_PROCESS_CAPTURE_PID=$process_pid
  wait "$process_pid" 2>/dev/null
  process_status=$?
  SF_PROCESS_CAPTURE_PID=''
  # A descendant outliving the process keeps the capture pipes open, so a
  # cancelled turn stops its readers instead of waiting for an EOF that a
  # process it no longer controls may never send.
  (( ! SF_PROCESS_CAPTURE_INTERRUPTED )) || kill -TERM $readers 2>/dev/null
  for reader in $readers; do
    wait $reader || reader_status=1
  done
  rm -f -- "$stdout_pipe" "$stderr_pipe" "$control_pipe"
  (( ! SF_PROCESS_CAPTURE_INTERRUPTED )) || return 130
  (( ! reader_status )) || return 1
  reply=( "$process_status" "$stdout" "$stderr" "$control" )
}

sf_process_capture_stop() {
  SF_PROCESS_CAPTURE_INTERRUPTED=1
  sf_process_stop "$SF_PROCESS_CAPTURE_PID"
}

# Signals one process. Callers spawn without job control, so the target leads no
# process group and its own descendants are its responsibility. See docs/CURSED.md.
sf_process_stop() {
  local pid=$1 watchdog
  [[ -n $pid ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
  {
    sleep 0.5
    kill -KILL "$pid" 2>/dev/null || true
  } &
  watchdog=$!
  wait "$pid" 2>/dev/null || true
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}
