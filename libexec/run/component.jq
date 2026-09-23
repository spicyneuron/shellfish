include "lib/session";

# The action fields of one fd 3 line, valid for the lifecycle. Tools pass null
# and take no action.
def component_action($lifecycle):
  ({user_prompt_submit:["block","handoff","session_update"],
    permission_request:["allow","deny"], pre_tool_use:["deny"],
    stop:["continue"]}[$lifecycle // ""] // []) as $actions |
  (.action | IN($actions[])) and
  if .action == "handoff" then keys == ["action","argv"] and
    (.argv | type == "array" and length > 0 and all(.[]; type == "string"))
  elif .action == "session_update" then keys == ["action","profile"] and
    (.profile | type == "object")
  elif .action == "deny" then keys == ["action"] or
    (keys == ["action","reason"] and (.reason | type == "string"))
  else keys == ["action"] end;

# One fd 3 line becomes its effects, or null when invalid. $draft is the
# transient event a draft fills in. A preview hint applies to the live section,
# so a line without one inherits $preview, the last hint since the previous
# result.
def component_line($lifecycle; $draft; $preview):
  if type == "object" then . else {"": null} end |
  (has("user_final") or has("model_final")) as $final |
  with_entries(select(.key | IN("action","argv","profile","reason"))) as $control |
  if ((keys - ["action","argv","model_final","profile","reason","state","user_draft",
      "user_final","user_preview_lines"]) | length == 0) and
    all(.user_draft, .user_final, .model_final; . == null or type == "string") and
    ((has("user_preview_lines") | not) or (.user_preview_lines | preview_hint)) and
    ((has("state") | not) or (.state | type == "array" and all(.[];
      type == "object" and keys == ["name","value"] and
      ({type:"state"} + . | canonical_state)))) and
    ($control == {} or ($control | component_action($lifecycle)))
  then
    (.user_preview_lines // $preview) as $hint |
    (if $hint == null then {} else {user_preview_lines:$hint} end) as $hinted |
    {final:$final, preview:$hint,
     states:[.state[]? | {type:"state"} + .],
     texts:(if $final then
       (if (.user_final // "") == "" then {} else {user_text:.user_final} end) +
       (if (.model_final // "") == "" then {} else {model_text:.model_final} end) +
       $hinted else null end),
     draft:($draft + {user_text:.user_draft} + $hinted |
       select(($final | not) and .user_text != null)) // null,
     control:$control}
  else null end;
