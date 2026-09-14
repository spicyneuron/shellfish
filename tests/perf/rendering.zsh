#!/usr/bin/env zsh

emulate -R zsh
setopt err_exit no_aliases no_multios pipe_fail
zmodload zsh/datetime

typeset -gr root=${0:A:h:h:h}
typeset turns_arg=${1:-50}
typeset iteration_arg=${2:-5}
(( $# <= 2 )) && [[ $turns_arg == <1-> && $iteration_arg == <1-> ]] || {
  print -u2 -r -- 'Usage: tests/perf/rendering.zsh [positive-turns] [positive-iterations]'
  exit 2
}
integer turns=$turns_arg iterations=$iteration_arg
integer characters=4096 tool_lines=64 columns=80 budget=45

typeset -g SF_ROOT=$root
source "$root/libexec/tui/render/main.zsh"

# Fake ZLE state keeps terminal commits quiet.
typeset -g PREDISPLAY='' POSTDISPLAY='' BUFFER='' CURSOR=0

# Drain safe batches before building the viewport.
present_drain() {
  while true; do
    sf_tui_transcript $columns $budget stage
    (( SF_PRESENT_SAFE_ROWS )) || break
    sf_tui_terminal_stage
    sf_tui_terminal_finish
    sf_tui_terminal_restore
  done
}

build_tool_text() {
  local line block=''
  local -a lines=(
    'Ordinary prose exercises wrapping without syntax highlighting.'
    'Short sentences include commas, periods, and repeated words.'
    'Stable synthetic text keeps benchmark input reproducible.'
    'Each source line occupies the same fixed character width.'
  )
  for line in $lines; do
    printf -v line '%-63.63s\n' "$line"
    block+=$line
  done
  REPLY=''
  repeat $(( tool_lines / ${#lines} )); do REPLY+=$block; done
}

build_session() {
  local session=$1
  integer count=$2 index
  cp "$root/tests/fixtures/session/header-only.jsonl" "$session" || exit 1
  for (( index = 1; index <= count; index++ )); do
    print -r -- "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Question $index\"}]}"
    print -r -- "{\"type\":\"assistant\",\"stop\":\"end\",\"content\":[{\"type\":\"text\",\"text\":\"Answer $index\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
  done >>"$session"
}

run_tool() {
  local content=$1
  sf_tui_reset
  sf_tui_terminal_reset
  sf_tui_event tool_call diff 'edit_file · path' edit_file 0
  sf_tui_event tool_result diff "$content" edit_file -1
  float start=$EPOCHREALTIME
  sf_tui_transcript $columns $(( tool_lines + 10 ))
  REPLY=$(( (EPOCHREALTIME - start) * 1000 ))
}

run_resume() {
  local session=$1
  sf_tui_terminal_reset
  float start=$EPOCHREALTIME
  sf_tui_reload "$session" || { print -u2 -r -- "$SF_PRESENT_ERROR"; exit 1; }
  present_drain
  REPLY=$(( (EPOCHREALTIME - start) * 1000 ))
}

measure_case() {
  local action=$1
  integer iteration
  shift
  float elapsed total=0 minimum=0 maximum=0
  for (( iteration = 1; iteration <= iterations; iteration++ )); do
    $action "$@"
    elapsed=$REPLY
    (( iteration > 1 && elapsed >= minimum )) || minimum=$elapsed
    (( iteration > 1 && elapsed <= maximum )) || maximum=$elapsed
    (( total += elapsed ))
  done
  reply=( $(( total / iterations )) $minimum $maximum )
}

measure_tool() {
  build_tool_text
  local content=$REPLY
  measure_case run_tool "$content"
  printf '%-21s %6d %10.3f %9.3f %9.3f\n' \
    'Plain tool text' $iterations $reply
}

typeset tmp
tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-render-perf.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
build_session "$tmp/session-$turns.jsonl" $turns
build_session "$tmp/session-$(( turns * 2 )).jsonl" $(( turns * 2 ))

print -P -- "%BTool rendering ($characters characters, $columns columns)%b"
printf '%-21s %6s %10s %9s %9s\n' Case Runs 'Mean (ms)' 'Min (ms)' 'Max (ms)'
printf '%-21s %6s %10s %9s %9s\n' --------------------- ------ ---------- --------- ---------
measure_tool
print

print -P -- "%BResume presentation ($columns columns, ${budget}-row viewport)%b"
printf '%-21s %7s %6s %10s %9s %9s\n' Case Turns Runs 'Mean (ms)' 'Min (ms)' 'Max (ms)'
printf '%-21s %7s %6s %10s %9s %9s\n' --------------------- ------- ------ ---------- --------- ---------
measure_case run_resume "$tmp/session-$turns.jsonl"
printf '%-21s %7d %6d %10.3f %9.3f %9.3f\n' \
  'Resume transcript' $turns $iterations $reply
measure_case run_resume "$tmp/session-$(( turns * 2 )).jsonl"
printf '%-21s %7d %6d %10.3f %9.3f %9.3f\n' \
  'Resume transcript' $(( turns * 2 )) $iterations $reply
print
