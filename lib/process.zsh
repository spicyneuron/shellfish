emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

sf_process_stop() {
  local pid=$1 target=$1 watchdog
  [[ -n $pid ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null && target="-$pid" ||
    kill -TERM "$pid" 2>/dev/null || true
  kill -CONT -- "$target" 2>/dev/null || true
  {
    sleep 0.5
    kill -KILL -- "$target" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  } &
  watchdog=$!
  wait "$pid" 2>/dev/null || true
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}
