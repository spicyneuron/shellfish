emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system
zmodload zsh/zselect

typeset -g SF_PROCESS_ERROR=''

sf_process_fail() {
  SF_PROCESS_ERROR=$1
  REPLY=''
  reply=()
  return 1
}

sf_process_isolated_run() {
  emulate -L zsh
  setopt no_aliases no_bg_nice no_monitor no_multios
  local group_file=$1 status_file=$2 working=$3 input=$4 stdout=$5 stderr=$6
  local control=$7 script_set=$8 script_value=$9
  shift 9
  integer child process_status

  print -r -- $sysparams[pid] >$group_file || return
  cd -- "$working" || return
  if (( script_set >= 0 )); then
    (( script_set )) && export SCRIPT=$script_value || unset SCRIPT
  fi
  "$@" <"$input" >"$stdout" 2>"$stderr" 3>"$control" &
  child=$!
  wait $child
  process_status=$?
  print -r -- $process_status >$status_file
}

sf_process_isolated_command() {
  local group_file=$1 status_file=$2 working=$3 input=$4 stdout=$5 stderr=$6
  local control=$7 runner script_value=''
  shift 7
  integer script_set=-1
  runner='source "$1" || exit; shift; sf_process_isolated_run "$@"'
  if [[ $OSTYPE == linux* ]] && (( $+commands[setsid] )); then
    reply=( "$commands[setsid]" "$commands[zsh]" -f -c "$runner" --
      "$SF_ROOT/lib/process.zsh" "$group_file" "$status_file" "$working" "$input"
      "$stdout" "$stderr" "$control" $script_set "$script_value" "$@" )
  elif [[ $OSTYPE == darwin* && -x /usr/bin/script ]]; then
    if [[ ${parameters[SCRIPT]-} == *export* ]]; then
      script_set=1
      script_value=$SCRIPT
    else
      script_set=0
    fi
    reply=( /usr/bin/script -q -e /dev/null "$commands[zsh]" -f -c "$runner" --
      "$SF_ROOT/lib/process.zsh" "$group_file" "$status_file" "$working" "$input"
      "$stdout" "$stderr" "$control" $script_set "$script_value" "$@" )
  else
    return 1
  fi
}

sf_process_wait() {
  local pid=$1 group_file=$2 status_file=$3
  integer group=0 process_status=1
  wait "$pid" 2>/dev/null || true
  [[ -r $group_file ]] && read -r group <"$group_file" 2>/dev/null || group=0
  (( group > 0 )) && kill -KILL -- -$group 2>/dev/null || true
  if [[ -r $status_file ]] && read -r process_status <"$status_file" 2>/dev/null &&
      [[ $process_status == <-> ]]; then
    REPLY=$process_status
    return 0
  fi
  REPLY=1
  return 1
}

sf_process_stop() {
  local pid=$1 group_file=${2-}
  integer group=0 polls=0
  [[ -n $pid ]] || return 0
  while [[ -n $group_file && ! -s $group_file ]] && (( polls++ < 50 )) &&
      kill -0 "$pid" 2>/dev/null; do
    zselect -t 1 2>/dev/null || true
  done
  [[ -z $group_file || ! -r $group_file ]] ||
    read -r group <"$group_file" 2>/dev/null || group=0
  if (( group > 0 )); then
    kill -TERM -- -$group 2>/dev/null || true
    kill -CONT -- -$group 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
  fi
  polls=0
  if (( group > 0 )); then
    while (( polls++ < 50 )) && kill -0 -- -$group 2>/dev/null; do
      zselect -t 1 2>/dev/null || true
    done
    kill -KILL -- -$group 2>/dev/null || true
  else
    while (( polls++ < 50 )) && kill -0 "$pid" 2>/dev/null; do
      zselect -t 1 2>/dev/null || true
    done
  fi
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

sf_process_capture_stream() {
  local pipe=$1 output=$2 chunk stored_chunk
  integer limit=$3 input_fd output_fd room stored=0
  local LC_ALL=C

  exec {input_fd}<"$pipe" && exec {output_fd}>"$output" || return 1
  while sysread -i $input_fd -s 4096 chunk; do
    room=$(( limit - stored ))
    if (( room > 0 )); then
      stored_chunk=${chunk[1,room]}
      print -rn -u $output_fd -- "$stored_chunk"
      (( stored += ${#stored_chunk} ))
    fi
  done
  exec {input_fd}<&-
  exec {output_fd}>&-
}

# Stream fd 3 to HANDLER one nonempty line at a time while the command runs. A
# final line without a newline arrives at exit. Lines stop once fd 3 exceeds
# MAX_CAPTURE bytes.
sf_process_run() {
  setopt local_options local_traps no_err_exit no_monitor
  local capture=${1:A} working=$2 input=$3
  integer max_capture=$4
  local handler=$5
  shift 5
  local stdout="$capture/stdout" stderr="$capture/stderr"
  local stdout_pipe="$stdout.pipe" stderr_pipe="$stderr.pipe" control_pipe="$capture/control.pipe"
  local group_file="$capture/process.group" status_file="$capture/process.status"
  local chunk buffer='' line
  local -a command=( "$@" ) process_command readers
  integer limit stdout_bytes stderr_bytes control_bytes=0 count control_fd=-1 guard_fd
  integer process_pid=0 process_status=1 reader reader_status=0 signal_status=0 complete=0

  SF_PROCESS_ERROR=''
  REPLY=''
  reply=()
  [[ -d $capture && ! -L $capture ]] || {
    sf_process_fail 'invalid process capture directory'
    return
  }
  [[ -z $(find "$capture" -mindepth 1 -print -quit 2>/dev/null) ]] || {
    sf_process_fail 'process capture directory is not empty'
    return
  }
  [[ -f $input && -r $input && -d $working && -x $working &&
      ${#command} -gt 0 && $command[1] == /* && -f $command[1] && -x $command[1] &&
      $max_capture -gt 0 ]] || {
    sf_process_fail 'process invocation is unavailable'
    return
  }

  sf_process_isolated_command "$group_file" "$status_file" "$working" "$input" \
    "$stdout_pipe" "$stderr_pipe" "$control_pipe" "${command[@]}" || {
    sf_process_fail 'cannot isolate process'
    return
  }
  process_command=( "${reply[@]}" )
  limit=$(( max_capture + 1 ))
  {
    mkfifo "$stdout_pipe" "$stderr_pipe" "$control_pipe" || {
      sf_process_fail 'cannot prepare process capture'
      return
    }
    sf_process_capture_stream "$stdout_pipe" "$stdout" $limit &
    readers+=( $! )
    sf_process_capture_stream "$stderr_pipe" "$stderr" $limit &
    readers+=( $! )
    # The wrapper holds one fd 3 writer until the command group is gone, so the
    # reader below neither blocks on open nor waits on a lingering descendant.
    {
      exec {guard_fd}>"$control_pipe" || exit 1
      "${process_command[@]}" </dev/null >/dev/null 2>&1 {guard_fd}>&- &
      sf_process_wait $! "$group_file" "$status_file"
    } &
    process_pid=$!
    exec {control_fd}<"$control_pipe" || {
      sf_process_fail 'cannot capture process output'
      return
    }
    trap 'signal_status=130; sf_process_stop "$process_pid" "$group_file"' INT USR1
    trap 'signal_status=129; sf_process_stop "$process_pid" "$group_file"' HUP
    trap 'signal_status=143; sf_process_stop "$process_pid" "$group_file"' TERM
    while sysread -c count -i $control_fd -s 4096 chunk; do
      (( control_bytes > max_capture )) && continue
      (( control_bytes += count ))
      (( control_bytes <= max_capture )) || continue
      buffer+=$chunk
      while [[ $buffer == *$'\n'* ]]; do
        line=${buffer%%$'\n'*}
        buffer=${buffer#*$'\n'}
        [[ -z $line ]] || "$handler" "$line"
      done
    done
    (( control_bytes > max_capture )) || [[ -z $buffer ]] || "$handler" "$buffer"
    if sf_process_wait "$process_pid" "$group_file" "$status_file"; then
      process_status=$REPLY
    elif (( signal_status )); then
      process_status=$signal_status
    else
      sf_process_fail 'cannot read process status'
      return
    fi
    for reader in $readers; do
      wait $reader || reader_status=1
    done
    (( ! reader_status )) || {
      sf_process_fail 'cannot capture process output'
      return
    }
    stdout_bytes=$(wc -c <"$stdout") && stderr_bytes=$(wc -c <"$stderr") || {
      sf_process_fail 'cannot inspect process capture'
      return
    }
    reply=( exit_code $process_status interrupted $(( signal_status != 0 ))
      stdout_bytes $stdout_bytes stderr_bytes $stderr_bytes control_bytes $control_bytes )
    REPLY=''
    complete=1
  } always {
    trap - INT USR1 HUP TERM
    (( control_fd < 0 )) || exec {control_fd}<&-
    (( process_pid == 0 || complete )) || sf_process_stop "$process_pid" "$group_file"
    (( complete )) || {
      for reader in $readers; do kill -TERM $reader 2>/dev/null; wait $reader 2>/dev/null; done
      rm -f -- "$stdout" "$stderr"
    }
    rm -f -- "$stdout_pipe" "$stderr_pipe" "$control_pipe" "$group_file" "$status_file"
  }
  (( complete ))
}
