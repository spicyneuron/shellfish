emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

typeset -g SF_PROCESS_CAPTURE_PID=''
typeset -gi SF_PROCESS_CAPTURE_INTERRUPTED=0

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
  local stdout_pipe="$stdout.pipe" stderr_pipe="$stderr.pipe" control_pipe="$control.pipe"
  local -a readers
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
  for reader in $readers; do
    wait $reader || reader_status=1
  done
  rm -f -- "$stdout_pipe" "$stderr_pipe" "$control_pipe"
  (( ! reader_status )) || return 1
  (( ! SF_PROCESS_CAPTURE_INTERRUPTED )) || return 130
  reply=( "$process_status" "$stdout" "$stderr" "$control" )
}

sf_process_capture_stop() {
  SF_PROCESS_CAPTURE_INTERRUPTED=1
  sf_process_stop "$SF_PROCESS_CAPTURE_PID"
}

sf_process_stop() {
  local pid=$1 target=$1 watchdog line owner child process
  local -A child_map=()
  local -a pending children=() fields branch
  integer alive=0
  [[ -n $pid ]] || return 0

  # A coprocess PID is not reliably its process-group ID in noninteractive zsh.
  for line in "${(@f)$(ps -axo pid=,ppid= 2>/dev/null)}"; do
    fields=( ${=line} )
    (( ${#fields} == 2 )) || continue
    child_map[$fields[2]]+=" $fields[1]"
  done
  pending=( "$pid" )
  while (( ${#pending} )); do
    owner=$pending[1]
    pending[1]=()
    branch=( ${=child_map[$owner]} )
    for child in "${branch[@]}"; do
      children=( "$child" "${children[@]}" )
      pending+=( "$child" )
    done
  done
  kill -TERM -- "-$pid" 2>/dev/null && target="-$pid" || true
  for process in "${children[@]}" "$pid"; do
    kill -TERM "$process" 2>/dev/null || true
    kill -CONT "$process" 2>/dev/null || true
  done
  [[ $target == $pid ]] || kill -CONT -- "$target" 2>/dev/null || true
  {
    sleep 0.5
    kill -KILL -- "$target" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    for process in "${children[@]}"; do
      kill -KILL "$process" 2>/dev/null || true
    done
  } &
  watchdog=$!
  wait "$pid" 2>/dev/null || true
  for process in "${children[@]}"; do
    if kill -0 "$process" 2>/dev/null; then
      alive=1
      break
    fi
  done
  (( alive )) || kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}
