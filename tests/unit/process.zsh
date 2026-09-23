#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_source lib/process.zsh
sf_test_tmp process

typeset command="$tmp/command" input_file="$tmp/input"
cat >"$command" <<'ZSH'
#!/usr/bin/env zsh
unsetopt bg_nice
input=$(<&0)
sleep 30 &
child=$!
print -rn -- "${PWD:A}|$RUNNER_VALUE|$1|$input|$child"
print -rn -u2 -- error
print -rn -u3 -- '{"state":[]}'
exit 7
ZSH
chmod +x "$command"
print -rn -- input >"$input_file"

typeset capture="$tmp/basic" stdout stderr child
typeset -a lines
typeset -A result
collect() { lines+=( "$1" ); }
mkdir "$capture"
capture=${capture:A}
sf_process_run "$capture" "$tmp" "$input_file" 512 collect \
  /usr/bin/env RUNNER_VALUE=ambient "$command" argument || { fail "$SF_PROCESS_ERROR"; exit 1; }
result=( "${reply[@]}" )
(( result[exit_code] == 7 && result[interrupted] == 0 && result[stdout_bytes] > 0 &&
   result[stderr_bytes] == 5 && result[control_bytes] == 12 )) ||
  fail 'runner returned an invalid result'
stdout="$capture/stdout"
stderr="$capture/stderr"
[[ $(<"$stdout") == "${tmp:A}|ambient|argument|input|"* ]] ||
  fail 'runner changed command input, cwd, environment, or arguments'
[[ $(<"$stderr") == error && ${(j:|:)lines} == '{"state":[]}' ]] ||
  fail 'runner mixed capture channels'
child=${$(<"$stdout")##*|}
! kill -0 "$child" 2>/dev/null || fail 'runner left a command descendant alive'
[[ -z $(find "$capture" -mindepth 1 ! -name stdout ! -name stderr -print -quit) ]] ||
  fail 'runner left internal files in the capture directory'

# Lines arrive while the command runs, even when split across writes.
typeset stream="$tmp/stream" stream_capture="$tmp/stream-capture" seen="$tmp/seen"
cat >"$stream" <<'ZSH'
#!/usr/bin/env zsh
print -rn -u3 -- '{"a":'
sleep 0.1
print -r -u3 -- '1}'
print -r -u3
integer waited=0
while (( waited++ < 100 )) && [[ ! -e $SEEN ]]; do sleep 0.02; done
[[ -e $SEEN ]]
ZSH
chmod +x "$stream"
mkdir "$stream_capture"
lines=()
collect() { lines+=( "$1" ); : >"$seen"; }
sf_process_run "$stream_capture" "$tmp" "$input_file" 512 collect \
  /usr/bin/env SEEN="$seen" "$stream" || fail "$SF_PROCESS_ERROR"
result=( "${reply[@]}" )
(( result[exit_code] == 0 )) || fail 'runner delivered no line before exit'
[[ ${(j:|:)lines} == '{"a":1}' ]] || fail "runner split or padded lines: $lines"
collect() { lines+=( "$1" ); }

# Each channel stops after one byte beyond its limit; an overlong fd 3 line stops delivery.
typeset overflow="$tmp/overflow" overflow_capture="$tmp/overflow-capture"
cat >"$overflow" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- ${(l:80::o:)}
print -rn -u2 -- ${(l:80::e:)}
print -rn -u3 -- ${(l:80::c:)}
ZSH
chmod +x "$overflow"
mkdir "$overflow_capture"
lines=()
sf_process_run "$overflow_capture" "$tmp" "$input_file" 16 collect "$overflow" ||
  fail "$SF_PROCESS_ERROR"
result=( "${reply[@]}" )
(( result[exit_code] == 0 && result[interrupted] == 0 && result[stdout_bytes] == 17 &&
   result[stderr_bytes] == 17 && result[control_bytes] > 16 && ! ${#lines} )) ||
  fail 'runner did not bound each capture channel'

# Interruption while streaming settles the result and stops the whole command group.
typeset interrupt="$tmp/interrupt" marker="$tmp/started" child_file="$tmp/child"
typeset interrupt_capture="$tmp/interrupt-capture" interrupt_result="$tmp/interrupt-result"
cat >"$interrupt" <<'ZSH'
#!/usr/bin/env zsh
unsetopt bg_nice
: >"$STARTED"
print -r -u3 -- streamed
sleep 30 &
print -r -- $! >"$CHILD_FILE"
wait
ZSH
chmod +x "$interrupt"
mkdir "$interrupt_capture"
(
  lines=()
  sf_process_run "$interrupt_capture" "$tmp" "$input_file" 16 collect \
    /usr/bin/env STARTED="$marker" CHILD_FILE="$child_file" "$interrupt" || exit
  result=( "${reply[@]}" )
  print -r -- "$result[exit_code] $result[interrupted] $lines" >"$interrupt_result"
) &
integer runner=$! waited=0
while (( waited++ < 100 )) && [[ ! -s $child_file ]]; do sleep 0.02; done
[[ -s $child_file ]] || fail 'runner command did not start'
kill -TERM "$runner"
wait "$runner" || fail 'runner did not settle an interrupted command'
[[ $(<"$interrupt_result") == '143 1 streamed' ]] ||
  fail 'runner did not report interruption'
child=$(<"$child_file")
! kill -0 "$child" 2>/dev/null || fail 'runner left an interrupted descendant alive'

# Invalid setup is a machinery failure, not a command result.
mkdir "$tmp/failure"
if sf_process_run "$tmp/failure" "$tmp/missing" "$input_file" 16 collect "$command"; then
  fail 'runner returned a command result for a machinery failure'
fi
[[ -n $SF_PROCESS_ERROR ]] || fail 'runner omitted its machinery error'
[[ -z $(find "$tmp/failure" -mindepth 1 -print -quit) ]] ||
  fail 'runner left files after a machinery failure'

# Commands must name executable regular files.
mkdir "$tmp/failure-command"
if sf_process_run "$tmp/failure-command" "$tmp" "$input_file" 16 collect "$tmp"; then
  fail 'runner accepted a directory as its command'
fi

# A launched isolation wrapper that omits status is a machinery failure.
typeset no_status="$tmp/no-status" no_status_capture="$tmp/no-status-capture"
cat >"$no_status" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- '' >"$1"
print -rn -- '' >"$2"
print -rn -- '' >"$3"
ZSH
chmod +x "$no_status"
sf_process_isolated_command() {
  reply=( "$no_status" "$5" "$6" "$7" )
}
mkdir "$no_status_capture"
if sf_process_run "$no_status_capture" "$tmp" "$input_file" 16 collect "$command"; then
  fail 'runner returned a command result without an isolation status'
fi
[[ $SF_PROCESS_ERROR == 'cannot read process status' ]] ||
  fail 'runner misdiagnosed a missing isolation status'
