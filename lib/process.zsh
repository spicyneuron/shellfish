emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

typeset -g SF_PROCESS_CAPTURE_PID=''
typeset -g SF_PROCESS_CAPTURE_GROUP_FILE=''
typeset -gi SF_PROCESS_CAPTURE_INTERRUPTED=0

sf_process_isolated_run() {
  emulate -L zsh
  setopt no_aliases no_bg_nice no_monitor no_multios
  local group_file=$1 status_file=$2 working=$3 input=$4 stdout=$5 stderr=$6
  local control=$7 mode=$8 script_set=$9 script_value=${10}
  shift 10
  integer child process_status

  print -r -- $sysparams[pid] >$group_file || return
  cd -- "$working" || return
  if (( script_set >= 0 )); then
    (( script_set )) && export SCRIPT=$script_value || unset SCRIPT
  fi
  if [[ $mode == separate ]]; then
    "$@" <"$input" >"$stdout" 2>"$stderr" 3>"$control" &
  else
    "$@" <"$input" >"$stdout" 2>&1 3>"$control" &
  fi
  child=$!
  wait $child
  process_status=$?
  print -r -- $process_status >$status_file
}

sf_process_isolated_command() {
  local group_file=$1 status_file=$2 working=$3 input=$4 stdout=$5 stderr=$6
  local control=$7 mode=$8 runner script_value=''
  shift 8
  integer script_set=-1
  runner='source "$1" || exit; shift; sf_process_isolated_run "$@"'
  if [[ $OSTYPE == linux* ]] && (( $+commands[setsid] )); then
    reply=( "$commands[setsid]" "$commands[zsh]" -f -c "$runner" --
      "$SF_ROOT/lib/process.zsh" "$group_file" "$status_file" "$working" "$input"
      "$stdout" "$stderr" "$control" "$mode" $script_set "$script_value" "$@" )
  elif [[ $OSTYPE == darwin* && -x /usr/bin/script ]]; then
    if [[ ${parameters[SCRIPT]-} == *export* ]]; then
      script_set=1
      script_value=$SCRIPT
    else
      script_set=0
    fi
    reply=( /usr/bin/script -q -e /dev/null "$commands[zsh]" -f -c "$runner" --
      "$SF_ROOT/lib/process.zsh" "$group_file" "$status_file" "$working" "$input"
      "$stdout" "$stderr" "$control" "$mode" $script_set "$script_value" "$@" )
  else
    return 1
  fi
}

# The control pipe is part of the capture contract: a sandboxed caller must
# expose this path before sf_process_capture creates it.
sf_process_control_pipe() {
  REPLY="$1/control.pipe"
}

sf_process_capture_stream() {
  local pipe=$1 output=$2 chunk
  integer limit=$3 fd
  local LC_ALL=C

  exec {fd}<"$pipe" || return
  {
    while sysread -i $fd -s 4096 chunk; do
      print -rn -- "$chunk"
    done
  } | tail -c "$limit" >"$output"
  local -a statuses=( $pipestatus )
  exec {fd}<&-
  (( statuses[1] == 0 && statuses[2] == 0 ))
}

sf_process_wait() {
  local pid=$1 group_file=$2 status_file=$3
  integer group=0 process_status=1
  wait "$pid" || true
  read -r group <"$group_file" 2>/dev/null || group=0
  (( group > 0 )) && kill -KILL -- -$group 2>/dev/null || true
  if read -r process_status <"$status_file" 2>/dev/null && [[ $process_status == <-> ]]; then
    REPLY=$process_status
    return 0
  fi
  REPLY=1
  return 1
}

# Captures one process while retaining at most one byte beyond the configured
# limit on each channel. The caller interprets the captured channels.
sf_process_capture() {
  local input=$1 directory=$2 working=$3 mode=$4
  integer max_capture=$5
  shift 5
  local stdout="$directory/stdout" stderr="$directory/stderr" control="$directory/control"
  local stdout_pipe="$stdout.pipe" stderr_pipe="$stderr.pipe" control_pipe REPLY
  local -a readers
  sf_process_control_pipe "$directory"
  control_pipe=$REPLY
  local group_file="$directory/process.group" status_file="$directory/process.status"
  local -a process_command
  integer limit=$(( max_capture + 1 )) process_pid process_status reader_status=0 reader
  setopt local_options no_err_exit no_monitor
  SF_PROCESS_CAPTURE_PID=''
  SF_PROCESS_CAPTURE_GROUP_FILE=''
  SF_PROCESS_CAPTURE_INTERRUPTED=0

  [[ $mode == (separate|merged) ]] || return 1
  sf_process_isolated_command "$group_file" "$status_file" "$working" "$input" \
    "$stdout_pipe" "$stderr_pipe" "$control_pipe" "$mode" "$@" || return 1
  process_command=( "${reply[@]}" )
  rm -f -- "$stdout" "$stderr" "$control" "$group_file" "$status_file" \
    "$stdout_pipe" "$stderr_pipe" "$control_pipe"
  mkfifo "$stdout_pipe" "$control_pipe" || return 1
  if [[ $mode == separate ]]; then
    mkfifo "$stderr_pipe" || return 1
  else
    : >"$stderr" || return 1
  fi

  sf_process_capture_stream "$stdout_pipe" "$stdout" $limit &
  readers+=( $! )
  sf_process_capture_stream "$control_pipe" "$control" $limit &
  readers+=( $! )
  if [[ $mode == separate ]]; then
    sf_process_capture_stream "$stderr_pipe" "$stderr" $limit &
    readers+=( $! )
  fi
  "${process_command[@]}" </dev/null >/dev/null 2>&1 &
  process_pid=$!
  SF_PROCESS_CAPTURE_PID=$process_pid
  SF_PROCESS_CAPTURE_GROUP_FILE=$group_file
  sf_process_wait "$process_pid" "$group_file" "$status_file" || true
  process_status=$REPLY
  SF_PROCESS_CAPTURE_PID=''
  SF_PROCESS_CAPTURE_GROUP_FILE=''
  # An escaped descendant may retain a capture pipe, so cancellation does not
  # rely on EOF from a process outside the isolated group.
  (( ! SF_PROCESS_CAPTURE_INTERRUPTED )) || kill -TERM $readers 2>/dev/null
  for reader in $readers; do
    wait $reader || reader_status=1
  done
  rm -f -- "$stdout_pipe" "$stderr_pipe" "$control_pipe" "$group_file" "$status_file"
  (( ! SF_PROCESS_CAPTURE_INTERRUPTED )) || return 130
  (( ! reader_status )) || return 1
  reply=( "$process_status" "$stdout" "$stderr" "$control" )
}

sf_process_capture_stop() {
  SF_PROCESS_CAPTURE_INTERRUPTED=1
  sf_process_stop "$SF_PROCESS_CAPTURE_PID" "$SF_PROCESS_CAPTURE_GROUP_FILE"
}

sf_process_stop() {
  local pid=$1 group_file=${2-}
  integer group=0 polls=0
  [[ -n $pid ]] || return 0
  while [[ -n $group_file && ! -s $group_file ]] && (( polls++ < 50 )) &&
      kill -0 "$pid" 2>/dev/null; do
    sleep 0.01
  done
  [[ -z $group_file ]] || read -r group <"$group_file" 2>/dev/null || group=0
  if (( group > 0 )); then
    kill -TERM -- -$group 2>/dev/null || true
    kill -CONT -- -$group 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
  fi
  polls=0
  if (( group > 0 )); then
    while (( polls++ < 50 )) && kill -0 -- -$group 2>/dev/null; do sleep 0.01; done
    kill -KILL -- -$group 2>/dev/null || true
  else
    while (( polls++ < 50 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.01; done
  fi
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
