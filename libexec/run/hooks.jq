include "lib/session";

# The action fields of one fd 3 line, valid for the lifecycle.
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

# One fd 3 line becomes its effects, or null when invalid. A final settles the
# live section into result $id.
def hook_line($lifecycle; $id):
  if type == "object" then . else {"": null} end |
  (has("user_final") or has("model_final")) as $final |
  with_entries(select(.key | IN("action","argv","reason","runtime"))) as $control |
  if ((keys - ["action","argv","model_final","reason","runtime","state","user_draft",
      "user_final","user_preview_lines"]) | length == 0) and
    all(.user_draft, .user_final, .model_final; . == null or type == "string") and
    ((has("user_preview_lines") | not) or (.user_preview_lines | preview_hint)) and
    ((has("state") | not) or (.state | type == "array" and all(.[];
      type == "object" and keys == ["name","value"] and
      ({type:"state"} + . | canonical_state)))) and
    ($control == {} or ($control | hook_action($lifecycle)))
  then
    (if has("user_preview_lines") then {user_preview_lines} else {} end) as $preview |
    {final:$final,
     states:[.state[]? | {type:"state"} + .],
     record:({type:"hook_result",lifecycle:$lifecycle,id:$id} +
       (if (.user_final // "") == "" then {} else {user_text:.user_final} end) +
       (if (.model_final // "") == "" then {} else {model_text:.model_final} end) +
       $preview | select($final and (has("user_text") or has("model_text")))) // null,
     draft:({type:"_hook_draft",lifecycle:$lifecycle,id:$id,user_text:.user_draft} +
       $preview | select(($final | not) and .user_text != null)) // null,
     control:$control}
  else null end;
