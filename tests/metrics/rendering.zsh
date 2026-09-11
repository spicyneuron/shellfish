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
source "$root/libexec/tui/render/main.zsh"

# ZLE parameters the commit boundary writes to. Nothing here runs under ZLE, so
# synchronized output stays quiet.
typeset -g PREDISPLAY='' POSTDISPLAY='' BUFFER='' CURSOR=0

# Styles make the renderer project spans rather than skipping that work. The
# preview defaults are already full, so no body is elided.
SF_PRESENT_STYLE=( message 'fg=7' divider 'fg=8' 'section.agent' bold
  clamp 'fg=8' activity 'fg=8'
  'syntax.strong' bold 'syntax.heading' 'bold,underline' 'syntax.code' 'fg=2' )

# Wrap to 80 columns, with the row budget a normal window leaves after the
# prompt chrome repaint reserves.
integer columns=80 budget=45

# Mirror the editor heartbeat: repaint, then commit every safe row before taking
# the next delta, or the benchmark measures only the first screenful.
present_feed() {
  sf_tui_event assistant_message_delta 0 "$1"
  sf_tui_transcript $columns $budget
  while (( SF_PRESENT_SAFE_ROWS )); do
    sf_tui_terminal_stage
    sf_tui_terminal_finish
    sf_tui_terminal_restore
    sf_tui_transcript $columns $budget
  done
}

typeset -ga deltas=()

build_prose() {
  integer count=$1 index
  deltas=()
  for (( index = 1; index <= count; index++ )); do
    deltas+=( "A streamed **prose** line with styled text and \`code\` $index"$'\n' )
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
    sf_tui_reset
    sf_tui_terminal_reset
    sf_tui_event assistant_start
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
