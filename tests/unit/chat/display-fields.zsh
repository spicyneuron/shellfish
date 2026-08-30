#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

typeset summary_tools=$(jq -cn \
  --slurpfile edit "$ROOT/default/tools/edit_file/tool.json" \
  --slurpfile shell "$ROOT/default/tools/shell/tool.json" '
    {harness:{tools:[
      {name:"edit_file",manifest:$edit[0]},
      {name:"shell",manifest:($shell[0] |
        .display.call.content=["$command"," (","$timeout","s)"])}]}}
')
assert_equal notes.txt "$(jq -nr -L "$ROOT/lib" --argjson tools "$summary_tools" '
  include "chat/display-fields";
  {name:"edit_file",input:{file_path:"notes.txt",old_string:"large",new_string:"secret"}} |
  tool_call_display($tools.harness.tools).content
')"
assert_equal 'make test (120s)' "$(jq -nr -L "$ROOT/lib" --argjson tools "$summary_tools" '
  include "chat/display-fields";
  {name:"shell",input:{command:"make test"}} | tool_call_display($tools.harness.tools).content
')"
assert_equal json "$(jq -nr -L "$ROOT/lib" --argjson tools "$summary_tools" '
  include "chat/display-fields";
  {name:"unknown",input:{value:1}} | tool_call_display($tools.harness.tools).format
')"
assert_equal plain "$(jq -nr -L "$ROOT/lib" --argjson tools "$summary_tools" '
  include "chat/display-fields";
  {name:"shell",input:{command:"true"}} | tool_call_display($tools.harness.tools).format
')"
jq -e '
  .harness.tools[0].manifest.display.result.exit_code == null and
  .harness.tools[0].manifest.display.result.always_full == true and
  .harness.tools[1].manifest.display.result.exit_code == true
' <<<"$summary_tools" >/dev/null || fail 'tool exit-code display policy was not loaded'

typeset framed
framed=$(jq -nj -L "$ROOT/lib" '
  include "chat/display-fields";
  [["notice", "before\u0000after", "", "", "", "", ""]] | emit_display_batch
' | tr '\0' '\n' | sed '/^$/d' | paste -sd, -)
assert_equal 'notice,before�after,batch_ok' "$framed"

if jq -nj -L "$ROOT/lib" '
    include "chat/display-fields";
    [["notice", "missing fields"]] | emit_display_batch
  ' >/dev/null 2>&1; then
  fail 'malformed display fields were accepted'
fi
