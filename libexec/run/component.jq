include "lib/session";
include "lib/profile";

# The action fields of one fd 3 line, valid for the lifecycle.
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

# Shared manifested-component protocol. Action fields are accepted only for hooks.
def component_update($lifecycle; $fields; $data; $templates; $name; $input; $preview; $draft):
  . as $line |
  (if type == "object" then
    with_entries(select(.key | IN("action","argv","profile","reason")))
  else {} end) as $control |
  if type != "object" or
    ((keys - ["state","data","user_text","user_text_done",
      "user_text_skipped","model_text","action","argv","profile","reason"]) | length) != 0 or
    ($control != {} and ($lifecycle == null or
      ($control | component_action($lifecycle) | not))) or
    (has("state") and (.state | type != "array" or any(.[];
      try ({type:"state"} + . | canonical_state | not) catch true))) or
    (has("data") and (.data | type != "object" or
      any(keys[]; test("^[A-Za-z_][A-Za-z0-9_]*$") | not) or
      any(.[]; type != "string"))) or
    (["user_text","user_text_done","user_text_skipped","model_text"] |
      any(.[]; . as $key | ($line | has($key)) and
        ($line[$key] | component_template($fields) | not)))
  then null
  else
    . as $line |
    ($data + ($line.data // {})) as $data |
    ($templates + ($line | with_entries(select(.key |
      IN("user_text","user_text_done","user_text_skipped","model_text"))))) as $templates |
    render_template($templates.user_text; $name; $input; {}; $data) as $text |
    {states:[$line.state[]? | {type:"state"} + .], data:$data,
     templates:$templates, control:$control,
     draft:($draft + {user_text:$text} +
       if $preview == null then {} else {user_preview_lines:$preview} end)}
  end;

def component_render($templates; $ran; $name; $input; $output; $data; $preview):
  (if $ran then $templates.user_text_done else $templates.user_text_skipped end) as $user |
  {user_text:render_template($user; $name; $input; $output; $data),
   model_text:render_template($templates.model_text; $name; $input; $output; $data)} |
  with_entries(select(.value != "")) +
  if $preview == null then {} else {user_preview_lines:$preview} end;
