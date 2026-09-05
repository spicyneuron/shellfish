# Runs a short command within an absolute EPOCHREALTIME deadline.

# Seconds a bundled probe chain may spend before it reports no context. Hosts
# where process startup or the file system is slow can raise the default.
typeset -gF SF_PROBE_BUDGET=1
if [[ ${SHELLFISH_PROBE_BUDGET-} == (<->|<->.<->) ]] &&
    (( SHELLFISH_PROBE_BUDGET > 0 )); then
  SF_PROBE_BUDGET=$SHELLFISH_PROBE_BUDGET
fi

sf_capped() {
  emulate -L zsh
  setopt no_bg_nice
  zmodload zsh/datetime
  zmodload zsh/zselect

  typeset -F deadline=$1
  shift
  local pid timer
  integer command_status=0 timer_status=0 ticks=$(( (deadline - EPOCHREALTIME) * 100 ))

  (( ticks > 0 )) || return 124
  "$@" &
  pid=$!
  (
    zselect -t "$ticks" || true
    kill -TERM "$pid" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  timer=$!
  wait "$pid" || command_status=$?
  kill -TERM "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || timer_status=$?
  (( timer_status == 0 )) && return 124
  return "$command_status"
}
