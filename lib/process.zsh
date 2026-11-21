emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system
zmodload zsh/zselect
zmodload -F zsh/stat b:zstat
zmodload -F zsh/files b:zf_rm

(( $+functions[sf_fail] )) || source "$SF_ROOT/lib/cli.zsh"

sf_process_isolation_launcher() {
  if [[ $OSTYPE == linux* ]] && (( $+commands[setsid] )); then
    reply=( "$commands[setsid]" )
  elif [[ $OSTYPE == darwin* && -x /usr/bin/script ]]; then
    reply=( /usr/bin/script -q -e /dev/null )
  else
    reply=()
    return 1
  fi
}

sf_process_isolated_run() {
  emulate -L zsh
  setopt no_aliases no_bg_nice no_monitor no_multios
  local group_file=$1 status_file=$2 working=$3 input=$4 stdout=$5 stderr=$6
  local control=$7 script_set=$8 script_value=$9
  shift 9
  integer child process_status terminating=0

  # Wait for the command's TERM handler before the caller reaps the group.
  trap 'terminating=1' TERM
  print -r -- $sysparams[pid] >$group_file || return
  cd -- "$working" || return
  if (( script_set >= 0 )); then
    (( script_set )) && export SCRIPT=$script_value || unset SCRIPT
  fi
  "$@" <"$input" >"$stdout" 2>"$stderr" 3>"$control" &
  child=$!
  while true; do
    wait $child
    process_status=$?
    (( terminating && process_status == 143 )) && kill -0 "$child" 2>/dev/null || break
  done
  print -r -- $process_status >$status_file
}

sf_process_isolated_command() {
  local group_file=$1 status_file=$2 working=$3 input=$4 stdout=$5 stderr=$6
  local control=$7 runner script_value=''
  local -a launcher
  shift 7
  integer script_set=-1
  runner='source "$1" || exit; shift; sf_process_isolated_run "$@"'
  sf_process_isolation_launcher || return 1
  launcher=( "${reply[@]}" )
  if [[ $OSTYPE == darwin* ]]; then
    if [[ ${parameters[SCRIPT]-} == *export* ]]; then
      script_set=1
      script_value=$SCRIPT
    else
      script_set=0
    fi
  fi
  reply=( "${launcher[@]}" "$commands[zsh]" -f -c "$runner" --
    "$SF_ROOT/lib/process.zsh" "$group_file" "$status_file" "$working" "$input"
    "$stdout" "$stderr" "$control" $script_set "$script_value" "$@" )
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
  setopt local_options no_multibyte
  local pipe=$1 output=$2 chunk stored=''
  integer limit=$3 input_fd output_fd
  local LC_ALL=C

  exec {input_fd}<"$pipe" && exec {output_fd}>"$output" || return 1
  while sysread -i $input_fd -s 4096 chunk; do
    stored+=$chunk
    (( ${#stored} <= limit )) || stored=${stored[-limit,-1]}
  done
  print -rn -u $output_fd -- "$stored"
  exec {input_fd}<&-
  exec {output_fd}>&-
}

sf_process_bytes() {
  setopt local_options no_multibyte
  REPLY=${#1}
}

# Stream fd 3 to HANDLER one nonempty line at a time while the command runs. A
# final line without a newline arrives at exit. control_bytes is the longest
# line; lines stop once one exceeds MAX_CONTROL bytes. interrupted is the
# signal exit status, or 0. With --poll CALLBACK, the owner calls CALLBACK at
# least every 100 ms and stops the command, setting cancelled, once it fails.
sf_process_run() {
  setopt local_options local_traps no_err_exit no_monitor
  local poll=''
  if [[ $1 == --poll ]]; then poll=$2; shift 2; fi
  local capture=${1:A} working=$2 input=$3
  integer max_capture=$4 max_control=$5
  local handler=$6
  shift 6
  local stdout="$capture/stdout" stderr="$capture/stderr"
  local stdout_pipe="$stdout.pipe" stderr_pipe="$stderr.pipe" control_pipe="$capture/control.pipe"
  local group_file="$capture/process.group" status_file="$capture/process.status"
  local chunk buffer='' line
  local -a command=( "$@" ) process_command readers sizes
  integer limit control_bytes=0 pending=0 control_fd=-1 guard_fd
  integer process_pid=0 process_status=1 reader reader_status=0 signal_status=0 complete=0 cancelled=0

  REPLY=''
  reply=()

  sf_process_isolated_command "$group_file" "$status_file" "$working" "$input" \
    "$stdout_pipe" "$stderr_pipe" "$control_pipe" "${command[@]}" || {
    sf_fail 'cannot isolate process'
    return
  }
  process_command=( "${reply[@]}" )
  limit=$(( max_capture + 1 ))
  {
    mkfifo "$stdout_pipe" "$stderr_pipe" "$control_pipe" || {
      sf_fail 'cannot prepare process capture'
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
      sf_fail 'cannot capture process output'
      return
    }
    trap 'signal_status=130; sf_process_stop "$process_pid" "$group_file"' INT USR1
    trap 'signal_status=129; sf_process_stop "$process_pid" "$group_file"' HUP
    trap 'signal_status=143; sf_process_stop "$process_pid" "$group_file"' TERM
    # Only a chunk with a newline rescans the buffer, so long lines stay linear.
    while true; do
      if [[ -n $poll ]]; then
        if ! "$poll"; then
          cancelled=1
          sf_process_stop "$process_pid" "$group_file"
          break
        fi
        zselect -r $control_fd -t 10 >/dev/null 2>&1 || continue
      fi
      sysread -i $control_fd -s 65536 chunk || break
      (( control_bytes > max_control )) && continue
      buffer+=$chunk
      sf_process_bytes "$chunk"
      (( pending += REPLY ))
      if [[ $chunk == *$'\n'* ]]; then
        while [[ $buffer == *$'\n'* ]]; do
          line=${buffer%%$'\n'*}
          buffer=${buffer:${#line}+1}
          sf_process_bytes "$line"
          (( REPLY <= max_control )) || { control_bytes=$REPLY; continue 2; }
          (( control_bytes = REPLY > control_bytes ? REPLY : control_bytes ))
          [[ -z $line ]] || "$handler" "$line"
        done
        sf_process_bytes "$buffer"
        pending=$REPLY
      fi
      (( control_bytes = pending > control_bytes ? pending : control_bytes ))
    done
    (( cancelled || control_bytes > max_control )) || [[ -z $buffer ]] || "$handler" "$buffer"
    if sf_process_wait "$process_pid" "$group_file" "$status_file"; then
      process_status=$REPLY
    elif (( signal_status || cancelled )); then
      process_status=$signal_status
    else
      sf_fail 'cannot read process status'
      return
    fi
    for reader in $readers; do
      wait $reader || reader_status=1
    done
    (( ! reader_status )) || {
      sf_fail 'cannot capture process output'
      return
    }
    zstat -A sizes +size -- "$stdout" "$stderr" || {
      sf_fail 'cannot inspect process capture'
      return
    }
    reply=( exit_code $process_status interrupted $signal_status cancelled $cancelled
      stdout_bytes $sizes[1] stderr_bytes $sizes[2] control_bytes $control_bytes )
    REPLY=''
    complete=1
  } always {
    trap - INT USR1 HUP TERM
    (( control_fd < 0 )) || exec {control_fd}<&-
    (( process_pid == 0 || complete )) || sf_process_stop "$process_pid" "$group_file"
    (( complete )) || {
      for reader in $readers; do kill -TERM $reader 2>/dev/null; wait $reader 2>/dev/null; done
      zf_rm -f -- "$stdout" "$stderr"
    }
    zf_rm -f -- "$stdout_pipe" "$stderr_pipe" "$control_pipe" "$group_file" "$status_file"
  }
  (( complete ))
}
