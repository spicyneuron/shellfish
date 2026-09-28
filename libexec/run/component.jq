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

# Immutable invocation values and initial presentation, before any fd 3 updates.
def component_plan($manifest; $kind; $name; $input; $draft):
  (if $kind == "tools" then
    {user_text:"${name} ${input}",
     user_text_done:"${name} ${input}\n${output.stdout}${output.stderr}",
     user_text_skipped:"${name} ${input}\n${output.stderr}",
     model_text:"${output.stdout}${output.stderr}"}
  else {user_text:"",user_text_done:"",user_text_skipped:"",model_text:""} end |
    . + ($manifest | with_entries(select(.value != null and (.key |
      IN("user_text","user_text_done","user_text_skipped","model_text")))))) as $templates |
  {name:$name,input:$input,templates:$templates,data:{},
   fields:($manifest.input_schema.properties // {} | keys | map("input." + .)),
   preview:($manifest.user_preview_lines // null),
   draft:($draft + {user_text:render_template($templates.user_text; $name; $input; {}; {})} +
     if $manifest.user_preview_lines == null then {} else
       {user_preview_lines:$manifest.user_preview_lines} end)};

# Shared manifested-component protocol. Action fields are accepted only for hooks.
def component_update($component):
  $component.draft.lifecycle as $lifecycle |
  $component.fields as $fields |
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
    ($component.data + ($line.data // {})) as $data |
    ($component.templates + ($line | with_entries(select(.key |
      IN("user_text","user_text_done","user_text_skipped","model_text"))))) as $templates |
    render_template($templates.user_text; $component.name; $component.input; {}; $data) as $text |
    {states:[$line.state[]? | {type:"state"} + .], control:$control,
     component:($component + {data:$data,templates:$templates,
       draft:($component.draft + {user_text:$text})})}
  end;

def component_result($component; $outcome):
  ($outcome.templates // $component.templates) as $templates |
  (if $outcome.ran then $templates.user_text_done else $templates.user_text_skipped end) as $user |
  ({user_text:render_template($user; $component.name; $component.input;
      $outcome.output; $outcome.data // {}),
    model_text:render_template($templates.model_text; $component.name; $component.input;
      $outcome.output; $outcome.data // {})} |
    with_entries(select(.value != "")) +
    if $component.preview == null then {} else
      {user_preview_lines:$component.preview} end) as $texts |
  ($component.draft | del(.user_text,.user_preview_lines)) as $identity |
  (if $identity.lifecycle != null then $identity + {type:"hook_result"}
   else $identity + {type:"tool_result",input:$component.input,
     exit_code:$outcome.output.exit_code} end) + $texts;
