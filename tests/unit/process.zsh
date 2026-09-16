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

typeset capture="$tmp/basic" stdout stderr control child
mkdir "$capture"
capture=${capture:A}
sf_process_run "$capture" "$tmp" "$input_file" 512 \
  /usr/bin/env RUNNER_VALUE=ambient "$command" argument || { fail "$SF_PROCESS_ERROR"; exit 1; }
(( reply[1] == 7 && reply[2] == 0 && reply[3] > 0 && reply[4] == 5 && reply[5] == 12 )) ||
  fail 'runner returned an invalid result'
stdout="$capture/stdout"
stderr="$capture/stderr"
control="$capture/control"
[[ $(<"$stdout") == "${tmp:A}|ambient|argument|input|"* ]] ||
  fail 'runner changed command input, cwd, environment, or arguments'
[[ $(<"$stderr") == error && $(<"$control") == '{"state":[]}' ]] ||
  fail 'runner mixed capture channels'
child=${$(<"$stdout")##*|}
! kill -0 "$child" 2>/dev/null || fail 'runner left a command descendant alive'
[[ -z $(find "$capture" -mindepth 1 ! -name stdout ! -name stderr ! -name control -print -quit) ]] ||
  fail 'runner left internal files in the capture directory'

# Each channel stops after one byte beyond its limit.
typeset overflow="$tmp/overflow" overflow_capture="$tmp/overflow-capture"
cat >"$overflow" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- ${(l:80::o:)}
print -rn -u2 -- ${(l:80::e:)}
print -rn -u3 -- ${(l:80::c:)}
ZSH
chmod +x "$overflow"
mkdir "$overflow_capture"
sf_process_run "$overflow_capture" "$tmp" "$input_file" 16 "$overflow" ||
  fail "$SF_PROCESS_ERROR"
(( reply[1] == 0 && reply[2] == 0 && reply[3] == 17 && reply[4] == 17 && reply[5] == 17 )) ||
  fail 'runner did not bound each capture channel'

# Interruption settles the result and stops the whole command group.
typeset interrupt="$tmp/interrupt" marker="$tmp/started" child_file="$tmp/child"
typeset interrupt_capture="$tmp/interrupt-capture" interrupt_result="$tmp/interrupt-result"
cat >"$interrupt" <<'ZSH'
#!/usr/bin/env zsh
unsetopt bg_nice
: >"$STARTED"
sleep 30 &
print -r -- $! >"$CHILD_FILE"
wait
ZSH
chmod +x "$interrupt"
mkdir "$interrupt_capture"
(
  sf_process_run "$interrupt_capture" "$tmp" "$input_file" 16 \
    /usr/bin/env STARTED="$marker" CHILD_FILE="$child_file" "$interrupt" || exit
  print -r -- "${(j: :)reply}" >"$interrupt_result"
) &
integer runner=$! waited=0
while (( waited++ < 100 )) && [[ ! -s $child_file ]]; do sleep 0.02; done
[[ -s $child_file ]] || fail 'runner command did not start'
kill -TERM "$runner"
wait "$runner" || fail 'runner did not settle an interrupted command'
[[ $(<"$interrupt_result") == '143 1 '* ]] ||
  fail 'runner did not report interruption'
child=$(<"$child_file")
! kill -0 "$child" 2>/dev/null || fail 'runner left an interrupted descendant alive'

# Invalid setup is a machinery failure, not a command result.
mkdir "$tmp/failure"
if sf_process_run "$tmp/failure" "$tmp/missing" "$input_file" 16 "$command"; then
  fail 'runner returned a command result for a machinery failure'
fi
[[ -n $SF_PROCESS_ERROR ]] || fail 'runner omitted its machinery error'
[[ -z $(find "$tmp/failure" -mindepth 1 -print -quit) ]] ||
  fail 'runner left files after a machinery failure'

# Commands must name executable regular files.
mkdir "$tmp/failure-command"
if sf_process_run "$tmp/failure-command" "$tmp" "$input_file" 16 "$tmp"; then
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
if sf_process_run "$no_status_capture" "$tmp" "$input_file" 16 "$command"; then
  fail 'runner returned a command result without an isolation status'
fi
[[ $SF_PROCESS_ERROR == 'cannot read process status' ]] ||
  fail 'runner misdiagnosed a missing isolation status'
