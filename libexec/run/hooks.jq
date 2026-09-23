include "lib/session";

# One fd 3 line: optional state and at most one action valid for the lifecycle.
def hook_action($lifecycle):
  ({user_prompt_submit:["block","handoff","session_update"],
    permission_request:["allow","deny"], pre_tool_use:["deny"],
    stop:["continue"]}[$lifecycle] // []) as $actions |
  (.action | IN($actions[])) and
  if .action == "handoff" then keys == ["action","argv"] and
    (.argv | type == "array" and length > 0 and all(.[]; type == "string"))
  elif .action == "session_update" then keys == ["action","runtime"] and
    (.runtime | type == "object")
  elif .action == "deny" then keys == ["action"] or
    (keys == ["action","reason"] and (.reason | type == "string"))
  else keys == ["action"] end;

def hook_line($lifecycle):
  type == "object" and
  ((has("state") | not) or (.state | type == "array" and all(.[];
    type == "object" and keys == ["name","value"] and
    ({type:"state"} + . | canonical_state)))) and
  (del(.state) | . == {} or hook_action($lifecycle));

# States from every line merge and the last action wins. Any invalid line or
# overflow voids the control.
def hook_outcome($lifecycle; $exit_code; $stdout; $stderr; $lines; $over_capture):
  ($over_capture == 0 and all($lines[]; hook_line($lifecycle))) as $valid |
  {output:{stdout:$stdout,stderr:$stderr,exit_code:$exit_code},
   valid:$valid,
   states:(if $valid then [$lines[].state[]? | {type:"state"} + .] else [] end),
   control:(if $valid then [$lines[] | del(.state) | select(. != {})] | last // {}
     else {} end)};
