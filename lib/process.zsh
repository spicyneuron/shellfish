emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

typeset -g SF_PROCESS_ERROR=''

sf_process_fail() {
  SF_PROCESS_ERROR=$1
  REPLY=''
  return 1
}

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

sf_process_wait() {
  local pid=$1 group_file=$2 status_file=$3
  integer group=0 process_status=1
  wait "$pid" || true
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

sf_process_run() {
  setopt local_options local_traps no_err_exit no_monitor
  local input=$1 capture=${2:A} decoded executable stdin working sandbox_executable
  local stdout="$capture/stdout" stderr="$capture/stderr" control="$capture/control"
  local stdout_pipe="$stdout.pipe" stderr_pipe="$stderr.pipe" control_pipe="$control.pipe"
  local group_file="$capture/process.group" status_file="$capture/process.status"
  local -a fields arguments environment sandbox_arguments command process_command readers
  integer argument_count environment_count sandbox_count index max_capture limit
  integer process_pid=0 process_status=1 reader reader_status=0 signal_status=0 complete=0

  SF_PROCESS_ERROR=''
  REPLY=''
  [[ -d $capture && ! -L $capture ]] || {
    sf_process_fail 'invalid process capture directory'
    return
  }
  [[ -z $(find "$capture" -mindepth 1 -print -quit 2>/dev/null) ]] || {
    sf_process_fail 'process capture directory is not empty'
    return
  }
  decoded=$(jq -jre '
    def path: type == "string" and startswith("/") and (index("\u0000") | not);
    def strings: type == "array" and all(.[]; type == "string" and (index("\u0000") | not));
    def field: ., "\u0000";
    select(type == "object" and
      keys == ["arguments","cwd","environment","executable","max_capture_bytes","sandbox","stdin"] and
      (.executable | path) and (.stdin | path) and (.cwd | path) and
      (.arguments | strings) and (.environment | strings) and
      (.max_capture_bytes | type == "number" and floor == . and . > 0) and
      (.sandbox == null or (.sandbox | type == "object" and
        keys == ["arguments","executable"] and (.executable | path) and (.arguments | strings)))) |
    (.executable | field), (.stdin | field), (.cwd | field),
    (.max_capture_bytes | tostring | field),
    (.arguments | length | tostring | field), (.arguments[] | field),
    (.environment | length | tostring | field), (.environment[] | field),
    ((.sandbox.executable // "") | field),
    ((.sandbox.arguments // []) | length | tostring | field),
    ((.sandbox.arguments // [])[] | field), ("ok" | field)
  ' <<<"$input" 2>/dev/null) || {
    sf_process_fail 'invalid process request'
    return
  }
  fields=( "${(@0)${decoded%$'\0'}}" )
  (( ${#fields} >= 8 )) && [[ $fields[-1] == ok ]] || {
    sf_process_fail 'invalid process request'
    return
  }
  executable=$fields[1]
  stdin=$fields[2]
  working=$fields[3]
  max_capture=$fields[4]
  argument_count=$fields[5]
  index=6
  arguments=( "${fields[@]:$(( index - 1 )):$argument_count}" )
  (( index += argument_count ))
  (( index <= ${#fields} )) || {
    sf_process_fail 'invalid process request'
    return
  }
  environment_count=$fields[index]
  (( index += 1 ))
  environment=( "${fields[@]:$(( index - 1 )):$environment_count}" )
  (( index += environment_count ))
  (( index + 2 <= ${#fields} )) || {
    sf_process_fail 'invalid process request'
    return
  }
  sandbox_executable=$fields[index]
  sandbox_count=$fields[index+1]
  (( index += 2 ))
  sandbox_arguments=( "${fields[@]:$(( index - 1 )):$sandbox_count}" )
  (( index + sandbox_count == ${#fields} )) || {
    sf_process_fail 'invalid process request'
    return
  }
  [[ -x $executable && -f $stdin && -r $stdin && -d $working && -x $working ]] || {
    sf_process_fail 'process request is unavailable'
    return
  }
  [[ -z $sandbox_executable || -x $sandbox_executable ]] || {
    sf_process_fail 'process sandbox is unavailable'
    return
  }

  command=( /usr/bin/env "${environment[@]}" "$executable" "${arguments[@]}" )
  [[ -z $sandbox_executable ]] ||
    command=( "$sandbox_executable" "${sandbox_arguments[@]}" -- "${command[@]}" )
  sf_process_isolated_command "$group_file" "$status_file" "$working" "$stdin" \
    "$stdout_pipe" "$stderr_pipe" "$control_pipe" separate "${command[@]}" || {
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
    sf_process_capture_stream "$control_pipe" "$control" $limit &
    readers+=( $! )
    "${process_command[@]}" </dev/null >/dev/null 2>&1 &
    process_pid=$!
    trap 'signal_status=130; sf_process_stop "$process_pid" "$group_file"' INT
    trap 'signal_status=143; sf_process_stop "$process_pid" "$group_file"' TERM
    sf_process_wait "$process_pid" "$group_file" "$status_file" || true
    process_status=$REPLY
    (( ! signal_status )) || process_status=$signal_status
    for reader in $readers; do
      wait $reader || reader_status=1
    done
    (( ! reader_status )) || {
      sf_process_fail 'cannot capture process output'
      return
    }
    REPLY=$(jq -cn --arg stdout "$stdout" --arg stderr "$stderr" --arg control "$control" \
      --argjson exit_code "$process_status" --argjson signal_status "$signal_status" \
      --argjson max "$max_capture" \
      --argjson stdout_bytes "$(wc -c <"$stdout")" \
      --argjson stderr_bytes "$(wc -c <"$stderr")" \
      --argjson control_bytes "$(wc -c <"$control")" '
        def channel($path; $bytes):
          {path:$path,bytes:$bytes,overflow:($bytes > $max)};
        {exit_code:$exit_code,interrupted:($signal_status != 0),
         stdout:channel($stdout;$stdout_bytes),stderr:channel($stderr;$stderr_bytes),
         control:channel($control;$control_bytes)}
      ') || {
      sf_process_fail 'cannot prepare process result'
      return
    }
    complete=1
  } always {
    trap - INT TERM
    (( process_pid == 0 || complete )) || sf_process_stop "$process_pid" "$group_file"
    (( complete )) || {
      for reader in $readers; do kill -TERM $reader 2>/dev/null; wait $reader 2>/dev/null; done
      rm -f -- "$stdout" "$stderr" "$control"
    }
    rm -f -- "$stdout_pipe" "$stderr_pipe" "$control_pipe" "$group_file" "$status_file"
  }
  (( complete ))
}
