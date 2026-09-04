#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

typeset summary_tools=$(jq -cn \
  --slurpfile edit "$ROOT/default/tools/edit_file/tool.json" \
  --slurpfile shell "$ROOT/default/tools/shell/tool.json" '
    {harness:{tools:[
      {name:"edit_file",manifest:$edit[0]},
      {name:"shell",manifest:($shell[0] |
        .display.summary=["$command"])}]}}
')
assert_equal notes.txt "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "tui/display-fields";
  {name:"edit_file",input:{file_path:"notes.txt",old_string:"large",new_string:"secret"}} |
  tool_call_display($tools.harness.tools).summary
')"
assert_equal 'make test' "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "tui/display-fields";
  {name:"shell",input:{command:"make test"}} | tool_call_display($tools.harness.tools).summary
')"
assert_equal '' "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "tui/display-fields";
  {name:"shell",input:{command:"make test"}} |
  tool_call_display([$tools.harness.tools[1] |
    .manifest.display.summary=["$timeout"]]).summary
')"
assert_equal json "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "tui/display-fields";
  {name:"unknown",input:{value:1}} | tool_call_display($tools.harness.tools).format
')"
assert_equal sh "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "tui/display-fields";
  {name:"shell",input:{command:"true"}} | tool_call_display($tools.harness.tools).format
')"
typeset replay
replay=$({
  head -n 1 "$ROOT/tests/fixtures/session/complete.jsonl"
  print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"question"}]}'
  print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"reasoning","text":"first"},{"type":"reasoning","text":""},{"type":"reasoning","text":"second"}]}'
} | jq -jRs -L "$ROOT" -f "$ROOT/tui/transcript-decode.jq")
typeset -a replay_fields=( "${(@0)${replay%$'\0'}}" )
# Replay leads with the frozen runtime from the durable header.
assert_equal session_update "$replay_fields[1]"
assert_equal fake-model "$(jq -r '.profile.request.model' <<<"$replay_fields[2]")"
assert_equal assistant "$replay_fields[15]"
assert_equal $'first\n\nsecond' "$replay_fields[17]"

# tail drops the leading session_update so only display events are compared.
typeset usage_replay
usage_replay=$({
  head -n 1 "$ROOT/tests/fixtures/session/complete.jsonl" |
    jq -c '.profile.context_window = 264000'
  print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"question"}]}'
  print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"answer"}],"usage":{"input_tokens":12400,"cached_tokens":10478,"output_tokens":900}}'
} | jq -jRs -L "$ROOT" -f "$ROOT/tui/transcript-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | tail -n +3 | paste -sd, -)
assert_equal 'user,question,assistant,answer,assistant_commit,turn_usage,12k ↑ 85% ⦿ 900 ↓ 5% of 264k ◔,batch_ok' "$usage_replay"
jq -e '
  .harness.tools[0].manifest.display.result.content == ["$result_full"] and
  .harness.tools[1].manifest.display.result.content == ["$result_preview", "$exit_code"] and
  .harness.tools[1].manifest.display.permission_preview ==
    {content:["$command"],format:"sh"}
' <<<"$summary_tools" >/dev/null || fail 'tool result display variables were not loaded'

# Short events are padded to the fixed width; the batch always ends in a marker.
typeset framed
framed=$(jq -nj -L "$ROOT" '
  include "tui/display-fields";
  [["notice", "before\u0000after"]] | emit_display_batch
' | tr '\0' '\n' | paste -sd, -)
assert_equal 'notice,before�after,,,,,,batch_ok,,,,,,' "$framed"

if jq -nj -L "$ROOT" '
    include "tui/display-fields";
    [["notice", "a", "b", "c", "d", "e", "f", "g"]] | emit_display_batch
  ' >/dev/null 2>&1; then
  fail 'an oversized display event was accepted'
fi

if jq -nj -L "$ROOT" '
    include "tui/display-fields";
    [["notice", 1]] | emit_display_batch
  ' >/dev/null 2>&1; then
  fail 'a non-string display field was accepted'
fi
