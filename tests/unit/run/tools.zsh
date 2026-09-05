#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh libexec/run/tools.zsh

sf_test_tmp tools
typeset session="$tmp/session.jsonl"
typeset tool_dir="$ROOT/share/default/tools/shell"
sf_test_runtime
sf_test_session "$session"
SF_SESSION_PATH=$session
typeset stored_runtime=$(head -n 1 "$session" | jq -c 'del(.type,.format_version,.cwd,.created)')
typeset stored_cwd=$(jq -r '.cwd' "$session")
typeset tool_tools tool_schema tool_cwd=$stored_cwd tool_max_capture tool_sandbox tool_fence
typeset tool_read_paths tool_write_paths tool_config_dir=''

load_tools() {
  local runtime=$1
  tool_tools=$(jq -c '.harness.tools' <<<$runtime)
  tool_max_capture=$(jq -r '.harness.max_capture_bytes' <<<$runtime)
  tool_sandbox=$(jq -r 'if .harness.sandbox then 1 else 0 end' <<<$runtime)
  tool_fence=$(jq -r '.harness.fence' <<<$runtime)
  tool_read_paths=$(jq -c '.harness.sandbox_read_paths' <<<$runtime)
  tool_write_paths=$(jq -c '.harness.sandbox_write_paths' <<<$runtime)
  sf_tools_load "$tool_tools" "$tool_cwd" "$tool_sandbox" "$tool_fence" \
    "$tool_read_paths" "$tool_write_paths"
  tool_schema=$REPLY
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
    "$tool_config_dir" "$SF_SESSION[id]" || return
}

# Tool execution preserves the caller's home in its otherwise clean environment.
load_tools "$stored_runtime"
[[ $SF_TOOL_COMMAND[shell] == "$tool_dir/run" &&
   $SF_TOOL_SANDBOX[shell] == true && $SF_TOOL_ALLOW_BYPASS[shell] == true &&
   $SF_TOOL_SETTINGS[shell] == "$tool_dir/fence.jsonc" ]] ||
  fail 'tool execution metadata was not cached'
sf_test_tool_execute '{"id":"unknown_1","name":"unknown","input":{}}' 0
jq -e '.exit_code == 127 and .content == "tool is not allowed: unknown"' <<<"$REPLY" >/dev/null
typeset invalid_tools=$(jq -c '.[0].command = "/missing/shellfish-tool"' <<<"$tool_tools")
if sf_tools_load "$invalid_tools" "$tool_cwd" "$tool_sandbox" "$tool_fence" \
    "$tool_read_paths" "$tool_write_paths"; then
  fail 'an unavailable tool command was accepted'
fi
(( ${#SF_TOOL_COMMAND} == 0 && ${#SF_TOOL_SANDBOX} == 0 &&
   ${#SF_TOOL_ALLOW_BYPASS} == 0 && ${#SF_TOOL_SETTINGS} == 0 )) ||
  fail 'a failed tool load retained executable metadata'
load_tools "$stored_runtime"
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$HOME"' \
  '{id:"home_1",name:"shell",input:{command:$command}}')" 0
jq -e --arg home "$HOME" '.content == $home' <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$TMPDIR"' \
  '{id:"temp_1",name:"shell",input:{command:$command}}')" 0
typeset tool_temp=$(jq -r '.content' <<<"$REPLY")
[[ $tool_temp == "${${TMPDIR:-/tmp}:A}/shellfish-$EUID/tooltemps/session-$SF_SESSION[id]-tmp" ]]
assert_equal 700 "$(stat -f %Lp "$tool_temp")"
sf_temp_directory native "$tool_temp"
typeset native_temp=$REPLY
integer native_grant=0
[[ $native_temp == $tool_temp ]] || native_grant=1
sf_test_tool_execute "$(jq -cn --arg command 'print -rn persistent >"$TMPDIR/marker"' \
  '{id:"temp_write",name:"shell",input:{command:$command}}')" 0
sf_test_tool_execute "$(jq -cn --arg command 'cat "$TMPDIR/marker"' \
  '{id:"temp_read",name:"shell",input:{command:$command}}')" 0
jq -e '.content == "persistent"' <<<"$REPLY" >/dev/null
tool_config_dir="$tmp/custom-config"
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$SHELLFISH_CONFIG_DIR"' \
  '{id:"config_dir_1",name:"shell",input:{command:$command}}')" 0
jq -e --arg config "$tool_config_dir" '.content == $config' <<<"$REPLY" >/dev/null
tool_config_dir=''
typeset caller_home=$HOME
mkdir "$tmp/home"
export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/xdg"
sf_test_tool_execute "$(jq -cn --arg command 'print -rn -- "$XDG_CONFIG_HOME"' \
  '{id:"xdg_config_1",name:"shell",input:{command:$command}}')" 0
jq -e --arg config "$XDG_CONFIG_HOME" '.content == $config' <<<"$REPLY" >/dev/null
export HOME=$caller_home
unset XDG_CONFIG_HOME

# Capture preserves trailing newlines and retains only the configured byte tail.
sf_test_tool_execute "$(jq -cn --arg command "printf 'line\\n\\n'" \
  '{id:"capture_1",name:"shell",input:{command:$command}}')" 0
jq -e '.content == "line\n\n" and .sandboxed == false' \
  <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn \
  '{id:"capture_bypass",name:"shell",input:{command:"true",request_sandbox_bypass:true,
    sandbox_bypass_reason:"test"}}')" 0
jq -e '.exit_code == 0' <<<"$REPLY" >/dev/null
tool_max_capture=64
sf_test_tool_execute "$(jq -cn --arg command "printf '%070d' 0" \
  '{id:"capture_2",name:"shell",input:{command:$command}}')" 0
jq -e '(.content | length) == 64 and (.content | startswith("[output truncated]\n"))' \
  <<<"$REPLY" >/dev/null

# Timeout terminates the command and returns the canonical timeout result.
sf_test_tool_execute "$(jq -cn \
  '{id:"timeout_1",name:"shell",input:{command:"sleep 5",timeout:1}}')" 0
jq -e '.exit_code == 124 and (.content | contains("timed out after 1 seconds"))' \
  <<<"$REPLY" >/dev/null

# A tool terminated by a signal is a completed tool call, not an exec cancellation.
sf_test_tool_execute "$(jq -cn \
  '{id:"signal_1",name:"shell",input:{command:"kill -TERM $$"}}')" 0
jq -e '.exit_code == 143 and .sandboxed == false' <<<"$REPLY" >/dev/null

# A sandboxed bypass executes only with an approval decision from its caller.
load_tools "$(jq -c --arg fence "${commands[fence]:A}" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")"
typeset bypass_call=$(jq -cn \
  '{id:"bypass_1",name:"shell",input:{command:"true",request_sandbox_bypass:true,
    sandbox_bypass_reason:"test"}}')
sf_tool_needs_permission shell true true 1
sf_test_tool_execute "$bypass_call" 1
jq -e '.exit_code == 126 and .content == "sandbox bypass denied"' \
  <<<"$REPLY" >/dev/null
sf_test_tool_execute "$bypass_call" 1 denied 'hook said no'
jq -e '.exit_code == 126 and .content == "hook said no"' <<<"$REPLY" >/dev/null
sf_test_tool_execute "$bypass_call" 1 approved
jq -e '.exit_code == 0 and .sandboxed == false' <<<"$REPLY" >/dev/null
if sf_tool_needs_permission shell false false 1; then
  fail 'a call without a bypass request asked for permission'
fi
sf_tool_needs_permission shell true false 1 &&
  fail 'a bypass request without a reason was accepted'
(( $? == 2 )) || fail 'a missing bypass reason did not report invalid input'

# Several tools project their schemas together and share one capture bound.
typeset file_runtime=$(jq -cn --argjson base "$stored_runtime" \
  --arg root "$ROOT/share/default/tools" \
  --slurpfile read "$ROOT/share/default/tools/read_file/tool.json" \
  --slurpfile edit "$ROOT/share/default/tools/edit_file/tool.json" \
  --slurpfile write "$ROOT/share/default/tools/write_file/tool.json" '
    $base | .harness.tools = [
      {name:"read_file",command:($root + "/read_file/run"),
       settings:(if $read[0].sandbox then ($root + "/read_file/fence.jsonc") else null end),manifest:$read[0]},
      {name:"edit_file",command:($root + "/edit_file/run"),
       settings:(if $edit[0].sandbox then ($root + "/edit_file/fence.jsonc") else null end),manifest:$edit[0]},
      {name:"write_file",command:($root + "/write_file/run"),
       settings:(if $write[0].sandbox then ($root + "/write_file/fence.jsonc") else null end),manifest:$write[0]}]
')
tool_cwd=$tmp
load_tools "$(jq -c '.harness.sandbox=true' <<<"$file_runtime")"
jq -e 'map(.name) == ["read_file","edit_file","write_file"] and
  all(.[].input_schema.properties; .request_sandbox_bypass.type == "boolean" and
    .sandbox_bypass_reason.minLength == 1) and
  all(.[].description; contains("keep it to one logical operation") | not)' \
  <<<"$tool_schema" >/dev/null
load_tools "$file_runtime"
(( ! ${+SF_TOOL_COMMAND[shell]} && ${+SF_TOOL_COMMAND[read_file]} )) ||
  fail 'replacing configured tools retained stale execution metadata'
tool_max_capture=64
typeset full_old=oldoldoldoldoldoldoldoldoldoldoldoldoldoldoldold
typeset full_new=newnewnewnewnewnewnewnewnewnewnewnewnewnewnewnew
print -r -- "$full_old" >"$tmp/full-diff.txt"
sf_test_tool_execute "$(jq -cn --arg old "$full_old" --arg new "$full_new" \
  '{id:"edit_full",name:"edit_file",input:{file_path:"full-diff.txt",old_string:$old,new_string:$new}}')" 0
jq -e '.content | length == 64 and startswith("[output truncated]\n")' \
  <<<"$REPLY" >/dev/null
tool_max_capture=$(jq -r '.harness.max_capture_bytes' <<<"$file_runtime")

# Sandboxed execution gives Fence the package policy path and runtime grants.
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
  --slurpfile manifest "$ROOT/share/default/tools/fetch_url/tool.json" '
    $base | .harness.tools = [{
      name:"fetch_url",command:($root + "/run"),
      settings:($root + "/fence.jsonc"),manifest:$manifest[0]
    }]
')
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$fetch_runtime")"
sf_test_tool_execute \
  '{"id":"fetch_1","name":"fetch_url","input":{"url":"https://example.com"}}' 1
jq -e '.exit_code == 0 and .content == "# sandboxed markdown\n"' <<<"$REPLY" >/dev/null
grep -Fx -- "$ROOT/share/default/tools/fetch_url/fence.jsonc" "$tmp/fence.settings" >/dev/null
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")"
sf_test_tool_execute "$(jq -cn --arg command 'printf "%s|%s" "$TMPDIR" "$TMPPREFIX"' \
  '{id:"fence_empty",name:"shell",input:{command:$command}}')" 1
jq -e --arg temp "$tool_temp" '.content == ($temp + "|" + $temp + "/zsh")' \
  <<<"$REPLY" >/dev/null
(( $(grep -Fxc -- '--expose-host-path-rw' "$tmp/fence.args") == 1 + native_grant ))
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
jq -e '.content == "fenced" and .sandboxed == true' \
  <<<"$REPLY" >/dev/null
grep -Fx -- '--monitor' "$tmp/fence.args" >/dev/null
grep -Fx -- '--fence-log-file' "$tmp/fence.args" >/dev/null
grep -Fx -- '--settings' "$tmp/fence.args" >/dev/null
grep -Fx -- "$tool_dir/fence.jsonc" "$tmp/fence.settings" >/dev/null
grep -Fx -- "$tool_dir/run" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/read dir" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/read file" "$tmp/fence.args" >/dev/null
(( $(grep -Fxc -- '--expose-host-path-rw' "$tmp/fence.args") == 3 + native_grant ))
grep -Fx -- "$tool_temp" "$tmp/fence.args" >/dev/null
(( ! native_grant )) || grep -Fx -- "$native_temp" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/write dir" "$tmp/fence.args" >/dev/null
grep -Fx -- "$tmp/write file" "$tmp/fence.args" >/dev/null
touch "$tmp/fence.violate"
sf_test_tool_execute "$(jq -cn --arg command 'printf blocked; exit 3' \
  '{id:"fence_blocked",name:"shell",input:{command:$command}}')" 1
jq -e '.content == "blocked" and .sandboxed == true and .sandbox_denial_detected == true' \
  <<<"$REPLY" >/dev/null
sf_test_tool_execute "$(jq -cn --arg command 'printf noisy' \
  '{id:"fence_noise",name:"shell",input:{command:$command}}')" 1
jq -e '.content == "noisy" and .sandboxed == true and (has("sandbox_denial_detected") | not)' \
  <<<"$REPLY" >/dev/null
rm "$tmp/fence.violate"
load_tools "$(jq -c --arg fence "$tmp/bin/fence" \
  '.harness.sandbox=true | .harness.fence=$fence' <<<"$stored_runtime")"
jq -e '.[0].input_schema.properties.request_sandbox_bypass.type == "boolean" and
  .[0].input_schema.properties.sandbox_bypass_reason.minLength == 1 and
  (.[0].input_schema.allOf[0].then.required | index("sandbox_bypass_reason")) != null and
  (.[0].description | contains("keep it to one logical operation"))' \
  <<<"$tool_schema" >/dev/null
