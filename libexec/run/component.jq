include "lib/session";
include "lib/profile";

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

# The nonempty texts a view settles to, or null when there are none. A view
# holds the fields its component wrote; $user and $model fill the others.
def component_texts($user; $model; $preview):
  {user_text:$user, model_text:$model} + . | with_entries(select(.value != "")) |
  if . == {} then null
  else . + if $preview == null then {} else {user_preview_lines:$preview} end end;

# One fd 3 line becomes its effects, or null when invalid. $view is the live
# section's view and $draft the transient event a user text fills in. A preview
# hint applies to the live section, so a line without one inherits $preview,
# the last hint since the previous result. Only a hook finalizes a section.
def component_line($lifecycle; $view; $draft; $preview):
  if type == "object" then . else {"": null} end |
  with_entries(select(.key | IN("action","argv","profile","reason"))) as $control |
  if ((keys - ["action","argv","finalize","model_text","profile","reason","state",
      "user_preview_lines","user_text"]) | length == 0) and
    all(.user_text, .model_text; . == null or type == "string") and
    ((has("finalize") | not) or .finalize == true) and
    ((has("user_preview_lines") | not) or (.user_preview_lines | preview_hint)) and
    ((has("state") | not) or (.state | type == "array" and all(.[];
      type == "object" and keys == ["name","value"] and
      ({type:"state"} + . | canonical_state)))) and
    ($control == {} or ($control | component_action($lifecycle)))
  then
    (.user_preview_lines // $preview) as $hint |
    ($view + with_entries(select(.key | IN("user_text","model_text")))) as $view |
    if .finalize and $lifecycle != null then
      {view:{}, preview:null, record:($view | component_texts(""; ""; $hint))}
    else
      {view:$view, preview:$hint, draft:(if has("user_text") | not then null else
        $draft + {user_text:.user_text} +
        if $hint == null then {} else {user_preview_lines:$hint} end end)}
    end + {states:[.state[]? | {type:"state"} + .], control:$control}
  else null end;

# Shared manifested-component protocol. Legacy file hooks use component_line.
def component_update($fields; $data; $templates; $name; $input; $preview; $draft):
  . as $line |
  if type != "object" or
    ((keys - ["state","data","user_text","user_text_done",
      "user_text_skipped","model_text"]) | length) != 0 or
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
     templates:$templates,
     draft:($draft + {user_text:$text} +
       if $preview == null then {} else {user_preview_lines:$preview} end)}
  end;

def component_render($templates; $ran; $name; $input; $output; $data; $preview):
  (if $ran then $templates.user_text_done else $templates.user_text_skipped end) as $user |
  {user_text:render_template($user; $name; $input; $output; $data),
   model_text:render_template($templates.model_text; $name; $input; $output; $data)} |
  with_entries(select(.value != "")) +
  if $preview == null then {} else {user_preview_lines:$preview} end;
