emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

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
