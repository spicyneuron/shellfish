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

typeset capture="$tmp/basic" request result stdout stderr control child
mkdir "$capture"
capture=${capture:A}
request=$(jq -cn --arg executable "$command" --arg stdin "$input_file" \
  --arg cwd "$tmp" '{
    executable:$executable,arguments:["argument"],stdin:$stdin,cwd:$cwd,
    environment:["RUNNER_VALUE=ambient"],sandbox:null,max_capture_bytes:512
  }')
sf_process_run "$request" "$capture" || { fail "$SF_PROCESS_ERROR"; exit 1; }
result=$REPLY
jq -e --arg capture "$capture" '
  keys == ["control","exit_code","interrupted","stderr","stdout"] and
  .exit_code == 7 and .interrupted == false and
  .stdout.path == ($capture + "/stdout") and .stdout.bytes > 0 and
  .stdout.overflow == false and
  .stderr == {path:($capture + "/stderr"),bytes:5,overflow:false} and
  .control == {path:($capture + "/control"),bytes:12,overflow:false}
' <<<"$result" >/dev/null || fail 'runner returned an invalid result'
stdout=$(jq -r '.stdout.path' <<<"$result")
stderr=$(jq -r '.stderr.path' <<<"$result")
control=$(jq -r '.control.path' <<<"$result")
[[ $(<"$stdout") == "${tmp:A}|ambient|argument|input|"* ]] ||
  fail 'runner changed command input, cwd, environment, or arguments'
[[ $(<"$stderr") == error && $(<"$control") == '{"state":[]}' ]] ||
  fail 'runner mixed capture channels'
child=${$(<"$stdout")##*|}
! kill -0 "$child" 2>/dev/null || fail 'runner left a command descendant alive'
[[ -z $(find "$capture" -mindepth 1 ! -name stdout ! -name stderr ! -name control -print -quit) ]] ||
  fail 'runner left internal files in the capture directory'

# A sandbox is an argv prefix around the environment and requested command.
typeset sandbox="$tmp/sandbox" sandbox_log="$tmp/sandbox.log" sandbox_capture="$tmp/sandbox-capture"
cat >"$sandbox" <<'ZSH'
#!/usr/bin/env zsh
printf '%s\n' "$@" >"$SANDBOX_LOG"
while [[ $1 != -- ]]; do shift; done
shift
exec "$@"
ZSH
chmod +x "$sandbox"
mkdir "$sandbox_capture"
export SANDBOX_LOG=$sandbox_log
request=$(jq -cn --arg executable "$command" --arg stdin "$input_file" \
  --arg cwd "$tmp" --arg sandbox "$sandbox" '{
    executable:$executable,arguments:["sandboxed"],stdin:$stdin,cwd:$cwd,
    environment:["RUNNER_VALUE=sandboxed"],
    sandbox:{executable:$sandbox,arguments:["wrap"]},max_capture_bytes:512
  }')
sf_process_run "$request" "$sandbox_capture" || fail "$SF_PROCESS_ERROR"
jq -Rsc --arg command "$command" '
  split("\n")[:-1] == ["wrap","--","/usr/bin/env","RUNNER_VALUE=sandboxed",$command,"sandboxed"]
' "$sandbox_log" >/dev/null || fail 'runner assembled the sandbox command incorrectly'

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
request=$(jq -cn --arg executable "$overflow" --arg stdin "$input_file" \
  --arg cwd "$tmp" '{
    executable:$executable,arguments:[],stdin:$stdin,cwd:$cwd,
    environment:[],sandbox:null,max_capture_bytes:16
  }')
sf_process_run "$request" "$overflow_capture" || fail "$SF_PROCESS_ERROR"
jq -e '
  .exit_code == 0 and .interrupted == false and
  all(.stdout,.stderr,.control; .bytes == 17 and .overflow == true)
' <<<"$REPLY" >/dev/null || fail 'runner did not bound each capture channel'

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
request=$(jq -cn --arg executable "$interrupt" --arg stdin "$input_file" \
  --arg cwd "$tmp" --arg marker "$marker" --arg child "$child_file" '{
    executable:$executable,arguments:[],stdin:$stdin,cwd:$cwd,
    environment:[("STARTED=" + $marker),("CHILD_FILE=" + $child)],
    sandbox:null,max_capture_bytes:16
  }')
(
  sf_process_run "$request" "$interrupt_capture" || exit
  print -r -- "$REPLY" >"$interrupt_result"
) &
integer runner=$! waited=0
while (( waited++ < 100 )) && [[ ! -s $child_file ]]; do sleep 0.02; done
[[ -s $child_file ]] || fail 'runner command did not start'
kill -TERM "$runner"
wait "$runner" || fail 'runner did not settle an interrupted command'
jq -e '.exit_code == 143 and .interrupted == true' "$interrupt_result" >/dev/null ||
  fail 'runner did not report interruption'
child=$(<"$child_file")
! kill -0 "$child" 2>/dev/null || fail 'runner left an interrupted descendant alive'

# Invalid setup is a machinery failure, not a command result.
mkdir "$tmp/failure"
request=$(jq -cn --arg executable "$command" --arg stdin "$input_file" \
  --arg cwd "$tmp/missing" '{
    executable:$executable,arguments:[],stdin:$stdin,cwd:$cwd,
    environment:[],sandbox:null,max_capture_bytes:16
  }')
if sf_process_run "$request" "$tmp/failure"; then
  fail 'runner returned a command result for a machinery failure'
fi
[[ -n $SF_PROCESS_ERROR ]] || fail 'runner omitted its machinery error'
[[ -z $(find "$tmp/failure" -mindepth 1 -print -quit) ]] ||
  fail 'runner left files after a machinery failure'
