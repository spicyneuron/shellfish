#!/usr/bin/env zsh

emulate -R zsh
setopt err_exit no_aliases no_multios pipe_fail
zmodload zsh/datetime

typeset -gr root=${0:A:h:h:h}
typeset size_arg=${1:-50}
typeset iteration_arg=${2:-5}
(( $# <= 2 )) && [[ $size_arg == <1-> && $iteration_arg == <1-> ]] || {
  print -u2 -r -- 'Usage: tests/perf/rendering.zsh [positive-lines] [positive-iterations]'
  exit 2
}
integer size=$size_arg iterations=$iteration_arg

typeset -g SF_ROOT=$root
source "$root/libexec/tui/render/main.zsh"

# ZLE parameters the commit boundary writes to. Nothing here runs under ZLE, so
# synchronized output stays quiet.
typeset -g PREDISPLAY='' POSTDISPLAY='' BUFFER='' CURSOR=0

# Syntax styles make formatted cases project spans. Plain text remains the
# unstyled layout baseline. Preview defaults are full, so no body is elided.
SF_PRESENT_STYLE=( 'syntax.added' 'fg=2,bg=22' 'syntax.removed' 'fg=1,bg=52'
  'syntax.strong' bold 'syntax.heading' 'bold,underline' 'syntax.code' 'fg=2'
  'syntax.string' 'fg=2' 'syntax.number' 'fg=3' 'syntax.keyword' 'fg=5' )

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

# Resume drains final records through staging passes, then builds the viewport
# only when no safe batch remains.
present_drain() {
  while true; do
    sf_tui_transcript $columns $budget stage
    (( SF_PRESENT_SAFE_ROWS )) || break
    sf_tui_terminal_stage
    sf_tui_terminal_finish
    sf_tui_terminal_restore
  done
}

typeset -ga deltas=()

build_stream() {
  local mode=$1 delta
  integer count=$2 index line
  deltas=()
  for (( index = 1; index <= count; index++ )); do
    case $mode in
      line) deltas+=( "A streamed **prose** line with styled text and \`code\` $index"$'\n' ) ;;
      paragraph) deltas+=( 'A streamed paragraph fragment with styled text and a link ' ) ;;
      batch)
        delta=''
        for (( line = 1; line <= 10; line++ )); do
          delta+="A batched Markdown line $(( (index - 1) * 10 + line ))"$'\n'
        done
        deltas+=( "$delta" )
        ;;
    esac
  done
}

build_format() {
  local format=$1
  integer count=$2 index
  REPLY=''
  for (( index = 1; index <= count; index++ )); do
    case $format in
      plain) REPLY+="Plain text line $index with no highlighting"$'\n' ;;
      markdown) REPLY+="Markdown **line** $index with \`inline code\`"$'\n' ;;
      json) REPLY+="{\"index\":$index,\"active\":true,\"name\":\"entry-$index\"}"$'\n' ;;
      diff)
        if (( index % 2 )); then
          REPLY+="-removed diff line $index"$'\n'
        else
          REPLY+="+added diff line $index"$'\n'
        fi
        ;;
    esac
  done
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

run_stream() {
  integer index
  sf_tui_reset
  sf_tui_terminal_reset
  sf_tui_event assistant_start
  float start=$EPOCHREALTIME
  for (( index = 1; index <= ${#deltas}; index++ )); do
    present_feed "$deltas[index]"
  done
  REPLY=$(( (EPOCHREALTIME - start) * 1000 ))
}

run_format() {
  local format=$1 content=$2
  integer count=$3
  sf_tui_reset
  sf_tui_terminal_reset
  sf_tui_event tool_call diff edit_file path '' plain
  sf_tui_event tool_result diff hidden "$content" "$format" full
  float start=$EPOCHREALTIME
  sf_tui_transcript $columns $(( count + 10 ))
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
  local label=$1 action=$3
  integer count=$2 iteration
  shift 3
  float elapsed total=0 minimum=0 maximum=0
  for (( iteration = 1; iteration <= iterations; iteration++ )); do
    $action "$@"
    elapsed=$REPLY
    (( iteration > 1 && elapsed >= minimum )) || minimum=$elapsed
    (( iteration > 1 && elapsed <= maximum )) || maximum=$elapsed
    (( total += elapsed ))
  done
  printf '%-21s %7d %6d %10.3f %9.3f %9.3f\n' \
    "$label" $count $iterations $(( total / iterations )) $minimum $maximum
}

measure_stream() {
  local label=$1 mode=$2
  integer count=$3
  build_stream $mode $count
  measure_case "$label" $count run_stream
}

measure_format() {
  local label=$1 content_type=$2 format=$3
  integer count=$4
  build_format $content_type $count
  local content=$REPLY
  measure_case "$label" $count run_format $format "$content" $count
}

typeset tmp
tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-render-perf.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
build_session "$tmp/session-$size.jsonl" $size
build_session "$tmp/session-$(( size * 2 )).jsonl" $(( size * 2 ))

print -P -- '%BFormat rendering%b'
printf '%-21s %7s %6s %10s %9s %9s\n' Format Lines Runs 'Mean (ms)' 'Min (ms)' 'Max (ms)'
printf '%-21s %7s %6s %10s %9s %9s\n' --------------------- ------- ------ ---------- --------- ---------
measure_format 'Plain text' plain plain $size
measure_format 'Plain text' plain plain $(( size * 2 ))
measure_format 'Markdown' markdown markdown $size
measure_format 'Markdown' markdown markdown $(( size * 2 ))
measure_format 'JSON' json json $size
measure_format 'JSON' json json $(( size * 2 ))
measure_format 'Diff' diff file_diff $size
measure_format 'Diff' diff file_diff $(( size * 2 ))
print

print -P -- '%BMarkdown streaming%b'
printf '%-21s %7s %6s %10s %9s %9s\n' Delivery Deltas Runs 'Mean (ms)' 'Min (ms)' 'Max (ms)'
printf '%-21s %7s %6s %10s %9s %9s\n' --------------------- ------- ------ ---------- --------- ---------
measure_stream 'One line per delta' line $size
measure_stream 'One line per delta' line $(( size * 2 ))
measure_stream 'Continuous paragraph' paragraph $size
measure_stream 'Continuous paragraph' paragraph $(( size * 2 ))
measure_stream '10 lines per delta' batch $size
measure_stream '10 lines per delta' batch $(( size * 2 ))
print

print -P -- '%BResume presentation%b'
printf '%-21s %7s %6s %10s %9s %9s\n' Case Turns Runs 'Mean (ms)' 'Min (ms)' 'Max (ms)'
printf '%-21s %7s %6s %10s %9s %9s\n' --------------------- ------- ------ ---------- --------- ---------
measure_case 'Resume transcript' $size run_resume "$tmp/session-$size.jsonl"
measure_case 'Resume transcript' $(( size * 2 )) run_resume "$tmp/session-$(( size * 2 )).jsonl"
print
