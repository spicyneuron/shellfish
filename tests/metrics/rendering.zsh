#!/usr/bin/env zsh

emulate -R zsh
setopt err_exit no_aliases no_multios pipe_fail
zmodload zsh/datetime

typeset -gr root=${0:A:h:h:h}
typeset size_arg=${1:-50}
typeset iteration_arg=${2:-3}
(( $# <= 2 )) && [[ $size_arg == <1-> && $iteration_arg == <1-> ]] || {
  print -u2 -r -- 'Usage: tests/metrics/rendering.zsh [positive-lines] [positive-iterations]'
  exit 2
}
integer size=$size_arg iterations=$iteration_arg

print -P -- '%BChat Rendering Performance%b'

typeset -g SF_ROOT=$root
source "$root/tui/render/main.zsh"

# Wrap to 80 columns. The engine also needs a row budget; view.zsh repaints
# with LINES - 5, so 45 stands in for a normal window. Full previews keep it
# from eliding a body it would otherwise lay out.
integer columns=80 budget=45
sf_chat_rows_config '{"tui":{"preview_lines_reasoning":"full","preview_lines_context":"full","preview_lines_tool_call":"full","preview_lines_tool_result":"full"}}'

# Mirror the editor heartbeat: repaint, then flush every settled row
# before taking the next delta. Rendering one bounded viewport per delta would
# leave the cursor at the head of the transcript and measure nothing but the
# first screenful.
present_feed() {
  sf_chat_event assistant_delta "$1"
  sf_chat_viewport $columns $budget "$SF_PRESENT_CURSOR"
  while (( SF_PRESENT_FLUSH_ROWS )); do
    sf_chat_terminal_stage
    sf_chat_terminal_finish
    sf_chat_viewport $columns $budget "$SF_PRESENT_CURSOR"
  done
}

typeset -ga deltas=()

build_prose() {
  integer count=$1 index
  deltas=()
  for (( index = 1; index <= count; index++ )); do
    deltas+=( "A streamed prose line with styled text and a link $index"$'\n' )
  done
}

build_long_line() {
  integer count=$1 index
  deltas=()
  for (( index = 1; index <= count; index++ )); do
    deltas+=( 'A streamed paragraph fragment with styled text and a link ' )
  done
}

build_multi_line() {
  integer count=$1 index group
  local delta
  deltas=()
  for (( index = 1; index <= count; index += 10 )); do
    delta=''
    for (( group = index; group < index + 10 && group <= count; group++ )); do
      delta+="A grouped prose line with styled text $group"$'\n'
    done
    deltas+=( "$delta" )
  done
}

measure_case() {
  local label=$1 builder=$2
  integer count=$3 index iteration
  float start elapsed total=0 minimum=0
  $builder $count
  for (( iteration = 1; iteration <= iterations; iteration++ )); do
    sf_chat_reset
    sf_chat_terminal_reset
    start=$EPOCHREALTIME
    for (( index = 1; index <= ${#deltas}; index++ )); do
      present_feed "$deltas[index]"
    done
    elapsed=$(( (EPOCHREALTIME - start) * 1000 ))
    (( iteration > 1 && elapsed >= minimum )) || minimum=$elapsed
    (( total += elapsed ))
  done
  printf '%-21s %7d %9.3f %9.3f\n' \
    "$label" ${#deltas} $(( total / iterations )) $minimum
}

printf '%-21s %7s %9s %9s\n' Case Deltas 'Mean (ms)' 'Min (ms)'
printf '%-21s %7s %9s %9s\n' --------------------- ------- --------- ---------
measure_case 'Prose lines' build_prose $size
measure_case 'Prose lines' build_prose $(( size * 2 ))
measure_case 'Long-line chunks' build_long_line $size
measure_case 'Long-line chunks' build_long_line $(( size * 2 ))
measure_case 'Up-to-10-line deltas' build_multi_line $size
measure_case 'Up-to-10-line deltas' build_multi_line $(( size * 2 ))
print
