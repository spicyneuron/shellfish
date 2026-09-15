#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh libexec/run/tools.zsh

sf_test_tmp tools
typeset session="$tmp/session.jsonl"
typeset tool_dir="$ROOT/share/default/tools/shell"
sf_test_runtime
sf_test_session "$session"
typeset stored_runtime=$(head -n 1 "$session" | jq -c 'del(.type,.format_version,.cwd,.created)')
typeset stored_cwd=$(jq -r '.cwd' "$session")
typeset tool_tools tool_schema tool_cwd=$stored_cwd tool_max_capture tool_sandbox tool_fence
typeset tool_read_paths tool_write_paths tool_config_dir='' tool_runtime
typeset tool_temp=''

load_tools() {
  local runtime=$1
  tool_runtime=$runtime
  tool_tools=$(jq -c '.harness.tools' <<<$runtime)
  tool_max_capture=$(jq -r '.harness.max_capture_bytes' <<<$runtime)
  tool_sandbox=$(jq -r 'if .harness.sandbox then 1 else 0 end' <<<$runtime)
  tool_fence=$(jq -r '.harness.fence' <<<$runtime)
  tool_read_paths=$(jq -c '.harness.sandbox_read_paths' <<<$runtime)
  tool_write_paths=$(jq -c '.harness.sandbox_write_paths' <<<$runtime)
  sf_tools_load "$tool_tools" "$tool_cwd" "$tool_sandbox" "$tool_fence" \
    "$tool_read_paths" "$tool_write_paths"
  tool_schema=$REPLY
  tool_temp=$SF_TOOL_TEMP_DIR
}

sf_test_tool_execute() {
  local call=$1 harness_sandbox=$2 decision=${3-} denial_reason=${4-}
  local id name execution_input bypass bypass_reason_valid projected
  local -a fields
  integer permission_status=0
  projected=$(jq -L "$ROOT" -jrn --argjson call "$call" '
    include "lib/request"; $call | tool_call_fields')
  fields=( "${(@0)${projected%$'\0'}}" )
  id=$fields[1]
  name=$fields[2]
  execution_input=$fields[4]
  bypass=$fields[5]
  bypass_reason_valid=$fields[6]
  sf_tool_needs_permission "$name" "$bypass" "$bypass_reason_valid" \
    "$harness_sandbox" || permission_status=$?
  (( permission_status != 2 )) || return
  sf_tool_execute "$id" "$name" "$execution_input" "$bypass" "$harness_sandbox" \
    "$decision" "$denial_reason" "$tool_cwd" "$tool_max_capture" "$tool_fence" \
    "$tool_config_dir" "$session" "$ROOT/bin/shellfish" \
    "$tool_runtime" || return
  REPLY=$SF_TOOL_OUTPUT
}

# Unsandboxed tools inherit the local environment.
export AMBIENT_TOOL_SETTING=ambient
load_tools "$stored_runtime"
sf_test_tool_execute '{"id":"unknown_1","name":"unknown","input":{}}' 0
jq -e '. == {stdout:"",stderr:"tool is not allowed: unknown",exit_code:127}' \
  <<<"$REPLY" >/dev/null
typeset invalid_tools=$(jq -c '.[0].command = "/missing/shellfish-tool"' <<<"$tool_tools")
if sf_tools_load "$invalid_tools" "$tool_cwd" "$tool_sandbox" "$tool_fence" \
    "$tool_read_paths" "$tool_write_paths"; then
  fail 'an unavailable tool command was accepted'
fi
load_tools "$stored_runtime"
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$AMBIENT_TOOL_SETTING"' \
  '{id:"ambient_1",name:"shell",input:{command:$command}}')" 0
jq -e '.stdout == "ambient" and .stderr == ""' <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$HOME"' \
  '{id:"home_1",name:"shell",input:{command:$command}}')" 0
jq -e --arg home "$HOME" '.stdout == $home' <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$TMPDIR"' \
  '{id:"temp_1",name:"shell",input:{command:$command}}')" 0
[[ $(jq -r '.stdout' <<<"$REPLY") == $tool_temp ]]
[[ $tool_temp == "${${TMPDIR:-/tmp}:A}/shellfish-$EUID/tooltemps/invocation."* ]]
assert_equal 700 "$(stat -f %Lp "$tool_temp")"
sf_temp_directory native "$tool_temp"
typeset native_temp=$REPLY
integer native_grant=0
[[ $native_temp == $tool_temp ]] || native_grant=1
sf_test_tool_execute "$(jq -cn --arg command 'print -rn persistent >"$TMPDIR/marker"' \
  '{id:"temp_write",name:"shell",input:{command:$command}}')" 0
sf_test_tool_execute "$(jq -cn --arg command 'cat "$TMPDIR/marker"' \
  '{id:"temp_read",name:"shell",input:{command:$command}}')" 0
jq -e '.stdout == "persistent"' <<<"$REPLY" >/dev/null
# Fixed tool context overrides selected environment.
typeset environment_runtime environment_call
tool_config_dir="$tmp/fixed-config"
export TOOL_SETTING=selected SHELLFISH_CONFIG_DIR=external SHELLFISH_SESSION=external
export SHELLFISH_EXECUTABLE=external SHELLFISH_MAX_CAPTURE_BYTES=64
environment_runtime=$(jq -c '
  .harness.tools[0].manifest.environment=["TOOL_SETTING","SHELLFISH_CONFIG_DIR",
    "SHELLFISH_SESSION","SHELLFISH_EXECUTABLE","SHELLFISH_MAX_CAPTURE_BYTES"]
' <<<"$stored_runtime") || fail 'cannot prepare tool environment runtime'
load_tools "$environment_runtime"
environment_call=$(jq -cn --arg command '
  print -rn -- "${TOOL_SETTING-unset}|$SHELLFISH_CONFIG_DIR|$SHELLFISH_SESSION|$SHELLFISH_EXECUTABLE|$SHELLFISH_MAX_CAPTURE_BYTES"
' '{id:"environment_1",name:"shell",input:{command:$command}}') || \
  fail 'cannot prepare tool environment call'
sf_test_tool_execute "$environment_call" 0
typeset expected_context="selected|$tool_config_dir|$session|$ROOT/bin/shellfish|$tool_max_capture"
jq -e --arg expected "$expected_context" '.stdout == $expected' <<<"$REPLY" >/dev/null
unset TOOL_SETTING SHELLFISH_CONFIG_DIR SHELLFISH_SESSION SHELLFISH_EXECUTABLE
unset SHELLFISH_MAX_CAPTURE_BYTES
tool_config_dir=''
load_tools "$stored_runtime"

# Capture keeps trailing newlines and the configured byte tail.
sf_test_tool_execute "$(jq -cn --arg command "printf 'line\\n\\n'" \
  '{id:"capture_1",name:"shell",input:{command:$command}}')" 0
jq -e '.stdout == "line\n\n" and .stderr == ""' \
  <<<"$REPLY" >/dev/null
tool_max_capture=64
sf_test_tool_execute "$(jq -cn --arg command "printf '%070d' 0" \
  '{id:"capture_2",name:"shell",input:{command:$command}}')" 0
jq -e '(.stdout | length) == 64 and (.stdout | startswith("[output truncated]\n"))' \
  <<<"$REPLY" >/dev/null

# Control bytes count against the output budget.
typeset state_tool="$tmp/state-tool" state_runtime control
cat >"$state_tool" <<'ZSH'
#!/usr/bin/env zsh
command=$(jq -r '.command' <&0) || exit 2
case $command in
  valid)
    printf '%0100d' 0
    print -rn -u3 -- '{"state":[{"name":"tools/result","value":7}]}'
    exit 7
    ;;
  malformed)
    print -rn -u3 -- '{'
    ;;
  overflow)
    printf '%0100d' 0 >&3
    ;;
esac
ZSH
chmod +x "$state_tool"
state_runtime=$(jq -c --arg command "$state_tool" '
  .harness.tools[0].command=$command
' <<<"$stored_runtime") || fail 'cannot prepare state tool runtime'
load_tools "$state_runtime"
tool_max_capture=96
control='{"state":[{"name":"tools/result","value":7}]}'
sf_test_tool_execute '{"id":"state_1","name":"shell","input":{"command":"valid"}}' 0
jq -e --argjson length "$(( tool_max_capture - ${#control} ))" '
  .exit_code == 7 and (.stdout | length) == $length and
  (.stdout | startswith("[output truncated]\n"))
' <<<"$REPLY" >/dev/null || fail 'tool control did not reserve the result budget'
[[ ${(pj:\n:)SF_TOOL_STATE_RECORDS} == \
  '{"type":"state","name":"tools/result","value":7}' ]] ||
  fail 'tool state was not returned canonically'
if sf_test_tool_execute \
    '{"id":"invalid_control","name":"shell","input":{"command":"malformed"}}' 0; then
  fail 'tool accepted malformed control'
fi
[[ ${#SF_TOOL_STATE_RECORDS} == 0 && -z $REPLY ]] ||
  fail 'failed control returned tool state or a result'
tool_max_capture=32
if sf_test_tool_execute \
    '{"id":"control_limit","name":"shell","input":{"command":"overflow"}}' 0; then
  fail 'tool accepted control beyond its capture budget'
fi
[[ $SF_TOOL_ERROR == 'tool control data exceeds capture limit' ]]

# Shell commands cannot write tool control.
load_tools "$stored_runtime"
sf_test_tool_execute "$(jq -cn --arg command \
  'print -rn -u3 -- leaked 2>/dev/null; print -rn -- closed' \
  '{id:"closed_control",name:"shell",input:{command:$command}}')" 0
jq -e '.exit_code == 0 and .stdout == "closed" and .stderr == ""' <<<"$REPLY" >/dev/null ||
  fail 'the bundled shell exposed tool control to its child command'
[[ ${#SF_TOOL_STATE_RECORDS} == 0 ]]

# Timeouts return canonical results.
sf_test_tool_execute "$(jq -cn \
  '{id:"timeout_1",name:"shell",input:{command:"sleep 5",timeout:1}}')" 0
jq -e '.exit_code == 124 and (.stderr | contains("timed out after 1 seconds"))' \
  <<<"$REPLY" >/dev/null

# Sandbox bypasses require approval.
typeset sandbox_runtime denied_runtime
sandbox_runtime=$(jq -c --arg fence "${commands[fence]:A}" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime") || \
  fail 'cannot prepare sandbox runtime'
load_tools "$sandbox_runtime"
typeset bypass_call=$(jq -cn \
  '{id:"bypass_1",name:"shell",input:{command:"print -rn -- $AMBIENT_TOOL_SETTING",request_sandbox_bypass:true,
    sandbox_bypass_reason:"test"}}')
sf_tool_needs_permission shell true true 1
sf_test_tool_execute "$bypass_call" 1
jq -e '.exit_code == 126 and .stderr == "sandbox bypass denied"' \
  <<<"$REPLY" >/dev/null
denied_runtime=$(jq -c --arg path "$tmp" '
  .backend.env_file=$path | .harness.tools[0].manifest.environment=["TOOL_SETTING"]
' <<<"$sandbox_runtime") || fail 'cannot prepare denied tool runtime'
load_tools "$denied_runtime"
sf_test_tool_execute "$bypass_call" 1
jq -e '.exit_code == 126 and .stderr == "sandbox bypass denied"' \
  <<<"$REPLY" >/dev/null || fail 'denied tool resolved its environment'
load_tools "$sandbox_runtime"
sf_test_tool_execute "$bypass_call" 1 denied 'hook said no'
jq -e '.exit_code == 126 and .stderr == "hook said no"' <<<"$REPLY" >/dev/null
sf_test_tool_execute "$bypass_call" 1 approved
jq -e '.exit_code == 0 and .stdout == "ambient" and .stderr == ""' <<<"$REPLY" >/dev/null
if sf_tool_needs_permission shell false false 1; then
  fail 'a call without a bypass request asked for permission'
fi
sf_tool_needs_permission shell true false 1 &&
  fail 'a bypass request without a reason was accepted'
(( $? == 2 )) || fail 'a missing bypass reason did not report invalid input'

# Fence receives tool policy and runtime grants.
mkdir "$tmp/bin"
cat >"$tmp/bin/fence" <<'ZSH'
#!/usr/bin/env zsh
print -rl -- "$@" >"${0:A:h:h}/fence.args"
print -r -- "$LANG" >"${0:A:h:h}/fence.lang"
print -r -- "$LC_ALL" >"${0:A:h:h}/fence.lc_all"
print -r -- "$LC_CTYPE" >"${0:A:h:h}/fence.lc_ctype"
print -r -- "$HOME" >"${0:A:h:h}/fence.home"
print -r -- "$TMPDIR" >"${0:A:h:h}/fence.tmpdir"
print -r -- "$TMPPREFIX" >"${0:A:h:h}/fence.tmpprefix"
typeset sandbox_log=''
while (( $# )) && [[ $1 != -- ]]; do
  case $1 in
    --fence-log-file) sandbox_log=$2; shift 2 ;;
    --settings) print -r -- "$2" >"${0:A:h:h}/fence.settings"; shift 2 ;;
    *) shift ;;
  esac
done
(( $# )) && shift
TMPDIR=/tmp/fence "$@"
integer code=$?
[[ ! -f "${0:A:h:h}/fence.violate" ]] ||
  print -r -- '[fence:test] 00:00:00 ✗ blocked' >"$sandbox_log"
exit $code
ZSH
chmod +x "$tmp/bin/fence"
cat >"$tmp/bin/curl" <<'ZSH'
#!/usr/bin/env zsh
print -r -- '# sandboxed markdown'
ZSH
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH"
rehash
typeset fetch_runtime=$(jq -cn --argjson base "$stored_runtime" \
  --arg root "$ROOT/share/default/tools/fetch_url" \
  --slurpfile manifest "$ROOT/share/default/tools/fetch_url/manifest.json" '
    $base | .harness.tools = [{
      name:"fetch_url",command:($root + "/run"),
      settings:($root + "/fence.jsonc"),manifest:$manifest[0]
    }]
')
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$fetch_runtime")"
sf_test_tool_execute \
  '{"id":"fetch_1","name":"fetch_url","input":{"url":"https://example.com"}}' 1
jq -e '.exit_code == 0 and .stdout == "# sandboxed markdown\n"' <<<"$REPLY" >/dev/null
grep -Fx -- "$ROOT/share/default/tools/fetch_url/fence.jsonc" "$tmp/fence.settings" >/dev/null
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")"
sf_test_tool_execute "$(jq -cn --arg command '
  printf "%s|%s|%s|%s|%s" "${AMBIENT_TOOL_SETTING-unset}" "$TMPDIR" "$TMPPREFIX" "$SHELLFISH_SESSION" "$SHELLFISH_EXECUTABLE"
' '{id:"fence_empty",name:"shell",input:{command:$command}}')" 1
jq -e --arg temp "$tool_temp" --arg session "$session" \
  --arg executable "$ROOT/bin/shellfish" '
    .stdout == ("unset|" + $temp + "|" + $temp + "/zsh|" + $session + "|" + $executable)
  ' <<<"$REPLY" >/dev/null
(( $(grep -Fxc -- '--expose-host-path-rw' "$tmp/fence.args") == 2 + native_grant ))
grep -Fx -- "$tool_temp" "$tmp/fence.args" >/dev/null
(( ! native_grant )) || grep -Fx -- "$native_temp" "$tmp/fence.args" >/dev/null
assert_equal "${LANG:-C}" "$(<"$tmp/fence.lang")"
assert_equal "$LC_ALL" "$(<"$tmp/fence.lc_all")"
assert_equal "$LC_CTYPE" "$(<"$tmp/fence.lc_ctype")"
assert_equal '' "$(<"$tmp/fence.tmpdir")"
assert_equal /tmp/zsh "$(<"$tmp/fence.tmpprefix")"
assert_equal "$HOME" "$(<"$tmp/fence.home")"
mkdir "$tmp/read dir" "$tmp/write dir"
touch "$tmp/read file" "$tmp/write file"
load_tools "$(jq -c --arg fence "$tmp/bin/fence" --arg read_dir "$tmp/read dir" \
  --arg read_file "$tmp/read file" --arg write_dir "$tmp/write dir" \
  --arg write_file "$tmp/write file" '
  .harness.sandbox=true | .harness.fence=$fence |
  .harness.sandbox_read_paths=[$read_dir,$read_file] |
  .harness.sandbox_write_paths=[$write_dir,$write_file]' <<<"$stored_runtime")"
sf_test_tool_execute "$(jq -cn --arg command 'printf fenced' \
  '{id:"fence_1",name:"shell",input:{command:$command}}')" 1
jq -e '.stdout == "fenced" and .stderr == ""' \
  <<<"$REPLY" >/dev/null
grep -Fx -- '--monitor' "$tmp/fence.args" >/dev/null
grep -Fx -- '--fence-log-file' "$tmp/fence.args" >/dev/null
grep -Fx -- '--settings' "$tmp/fence.args" >/dev/null
grep -Fx -- "$tool_dir/fence.jsonc" "$tmp/fence.settings" >/dev/null
grep -Fx -- "$tool_dir/run" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/read dir" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/read file" "$tmp/fence.args" >/dev/null
(( $(grep -Fxc -- '--expose-host-path-rw' "$tmp/fence.args") == 4 + native_grant ))
grep -Fx -- "$tool_temp" "$tmp/fence.args" >/dev/null
(( ! native_grant )) || grep -Fx -- "$native_temp" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/write dir" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/write file" "$tmp/fence.args" >/dev/null
touch "$tmp/fence.violate"
sf_test_tool_execute "$(jq -cn --arg command 'printf blocked; exit 3' \
  '{id:"fence_blocked",name:"shell",input:{command:$command}}')" 1
jq -e '.stdout == "blocked" and .stderr == ""' \
  <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn --arg command 'printf noisy' \
  '{id:"fence_noise",name:"shell",input:{command:$command}}')" 1
jq -e '.stdout == "noisy" and .stderr == ""' \
  <<<"$REPLY" >/dev/null
rm "$tmp/fence.violate"
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")"
jq -e '.[0].input_schema.properties.request_sandbox_bypass.type == "boolean" and
  .[0].input_schema.properties.sandbox_bypass_reason.minLength == 1 and
  (.[0].input_schema.allOf[0].then.required | index("sandbox_bypass_reason")) != null' \
  <<<"$tool_schema" >/dev/null

typeset final_temp=$tool_temp
sf_tools_cleanup
[[ ! -e $final_temp ]]
