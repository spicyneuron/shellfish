include "lib/session";

def hook_outcome($exit_code; $stdout; $stderr; $controls; $over_capture):
  ($controls | if length == 0 then {}
   elif length == 1 and (.[0] | type == "object") then .[0]
   else null end) as $control |
  ($control != null and $over_capture == 0 and
   ($control | if has("state") then
      .state | type == "array" and all(.[];
        type == "object" and keys == ["name","value"] and
        ({type:"state"} + . | canonical_state))
    else true end)) as $valid |
  {output:{stdout:$stdout,stderr:$stderr,exit_code:$exit_code},
   states:(if $valid then [$control.state[]? | {type:"state"} + .] else [] end),
   control:(if $valid then ($control | del(.state)) else {} end)} +
  (if $valid then {} else {control_invalid:true} end);

# Any non-empty result reaches the caller as one generic diagnostic.
def hook_control_error($lifecycle):
  . as $outcome | .control as $control |
  if has("control_invalid") then "invalid"
  elif $lifecycle == "user_prompt_submit" then
    if $outcome.output.exit_code == 11 then
      if ($control == {} or
          ($control.action == "handoff" and ($control | keys) == ["action","argv"] and
           ($control.argv | type == "array" and length > 0 and all(.[]; type == "string"))) or
          ($control.action == "session_update" and ($control | keys) == ["action","runtime"] and
           ($control.runtime | type == "object"))) then "" else "invalid" end
    elif $control == {} then "" else "invalid" end
  elif $lifecycle == "permission_request" and $outcome.output.exit_code == 11 then
    if ($control.action == "allow" and ($control | keys) == ["action"]) or
        ($control.action == "deny" and
          (($control | keys) == ["action"] or
           (($control | keys) == ["action","reason"] and ($control.reason | type == "string"))))
    then "" else "invalid" end
  elif $control == {} then "" else "invalid" end;
