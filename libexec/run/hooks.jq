include "lib/session";

def hook_outcome($exit_code; $stdout; $stderr; $controls; $capture_error):
  ($controls | if length == 0 then {}
   elif length == 1 and (.[0] | type == "object") then .[0]
   else null end) as $control |
  (if $control == null then "malformed control data"
   elif ($control | if has("state") then
      .state | type == "array" and all(.[];
        type == "object" and keys == ["name","value"] and
        ({type:"state"} + . | canonical_state))
    else true end) | not then "invalid state control"
   else $capture_error end) as $error |
  {exit_code:$exit_code,stdout:$stdout,stderr:$stderr,
   states:(if $error == "" then [$control.state[]? | {type:"state"} + .] else [] end),
   control:(if $error == "" then ($control | del(.state)) else {} end)} +
  (if $error == "" then {} else {control_error:$error} end);

def hook_control_error($lifecycle):
  . as $outcome | .control as $control |
  if has("control_error") then "decode"
  elif $lifecycle == "user_prompt_submit" then
    if $outcome.exit_code == 11 then
      if ($control == {} or
          ($control.action == "handoff" and ($control | keys) == ["action","argv"] and
           ($control.argv | type == "array" and length > 0 and all(.[]; type == "string"))) or
          ($control.action == "session_update" and ($control | keys) == ["action","runtime"] and
           ($control.runtime | type == "object"))) then "" else "lifecycle" end
    elif $control == {} then "" else "lifecycle" end
  elif $lifecycle == "permission_request" and $outcome.exit_code == 11 then
    if ($control.action == "allow" and ($control | keys) == ["action"]) or
        ($control.action == "deny" and
          (($control | keys) == ["action"] or
           (($control | keys) == ["action","reason"] and ($control.reason | type == "string"))))
    then "" else "lifecycle" end
  elif $control == {} then "" else "lifecycle" end;
