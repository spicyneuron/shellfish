#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

# Resolve tool display fields.
typeset summary_tools=$(jq -cn \
  --slurpfile edit "$ROOT/share/default/tools/edit_file/manifest.json" \
  --slurpfile shell "$ROOT/share/default/tools/shell/manifest.json" '
    {harness:{tools:[
      {name:"edit_file",manifest:$edit[0]},
      {name:"shell",manifest:($shell[0] |
        .display.summary=["$command"])}]}}
')
assert_equal notes.txt "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "libexec/tui/display-fields";
  {name:"edit_file",input:{file_path:"notes.txt",old_string:"large",new_string:"secret"}} |
  tool_call_display($tools.harness.tools).summary
')"
assert_equal 'make test' "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "libexec/tui/display-fields";
  {name:"shell",input:{command:"make test"}} | tool_call_display($tools.harness.tools).summary
')"
assert_equal sh "$(jq -nr -L "$ROOT" --argjson tools "$summary_tools" '
  include "libexec/tui/display-fields";
  {name:"shell",input:{command:"true"}} | tool_call_display($tools.harness.tools).format
')"

# Decode replay fields.
typeset replay
replay=$({
  head -n 1 "$ROOT/tests/fixtures/session/complete.jsonl"
  print -r -- '{"type":"state","name":"replay/start","value":true}'
  print -r -- '{"type":"user","content":[{"type":"text","text":"question"}]}'
  print -r -- '{"type":"state","name":"replay/middle","value":{"step":2}}'
  print -r -- '{"type":"assistant","stop":"end","content":[{"type":"reasoning","text":"first"},{"type":"reasoning","text":""},{"type":"reasoning","text":"second"},{"type":"text","text":"answer"},{"type":"reasoning","text":"last"}]}'
  print -r -- '{"type":"state","name":"replay/end","value":null}'
} | jq -jRs -L "$ROOT" -f "$ROOT/libexec/tui/transcript-decode.jq")
typeset -a replay_fields=( "${(@0)${replay%$'\0'}}" )
typeset -a replay_order=()
integer replay_index
for (( replay_index = 1; replay_index <= ${#replay_fields}; replay_index += 7 )); do
  case $replay_fields[replay_index] in
    assistant_start|assistant_end)
      replay_order+=( "$replay_fields[replay_index]" )
      ;;
    assistant_reasoning_delta|assistant_message_delta)
      replay_order+=( "$replay_fields[replay_index]:$replay_fields[replay_index + 1]:$replay_fields[replay_index + 2]" )
      ;;
  esac
done
assert_equal session_update "$replay_fields[1]"
assert_equal fake-model "$(jq -r '.profile.request.model' <<<"$replay_fields[2]")"
assert_equal \
  'assistant_start,assistant_reasoning_delta:0:first,assistant_reasoning_delta:1:,assistant_reasoning_delta:2:second,assistant_message_delta:3:answer,assistant_reasoning_delta:4:last,assistant_end' \
  "${(j:,:)replay_order}"

# Decode replay usage.
typeset usage_replay
usage_replay=$({
  head -n 1 "$ROOT/tests/fixtures/session/complete.jsonl" |
    jq -c '.profile.context_window = 264000'
  print -r -- '{"type":"user","content":[{"type":"text","text":"question"}]}'
  print -r -- '{"type":"assistant","stop":"end","content":[{"type":"reasoning","text":"why"},{"type":"text","text":"answer"}],"usage":{"input_tokens":12400,"cached_tokens":10478,"output_tokens":900,"reasoning_tokens":9}}'
} | jq -jRs -L "$ROOT" -f "$ROOT/libexec/tui/transcript-decode.jq" |
  tr '\0' '\n' | sed '/^$/d' | tail -n +3 | paste -sd, -)
assert_equal 'user,question,assistant_start,assistant_reasoning_delta,0,why,9,assistant_message_delta,1,answer,assistant_end,turn_usage,12k ↑ 85% ⦿ 900 ↓ 5% of 264k ◔,9,batch_ok' "$usage_replay"

# Sanitize framed fields.
typeset framed
framed=$(jq -nj -L "$ROOT" '
  include "libexec/tui/display-fields";
  [["sample", "before\u0000after"]] | emit_display_batch
' | tr '\0' '\n' | paste -sd, -)
assert_equal 'sample,before�after,,,,,,batch_ok,,,,,,' "$framed"
