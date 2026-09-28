include "lib/session";
include "lib/profile";

# The action fields of one fd 3 line, valid when the action is one of $actions.
def component_action($actions):
  (.action | IN($actions[])) and
  if .action == "handoff" then keys == ["action","argv"] and
    (.argv | type == "array" and length > 0 and all(.[]; type == "string"))
  elif .action == "session_update" then keys == ["action","profile"] and
    (.profile | type == "object")
  elif .action == "deny" then keys == ["action"] or
    (keys == ["action","reason"] and (.reason | type == "string"))
  else keys == ["action"] end;

# Invocation values and initial presentation. The manifest overrides $defaults.
def component_plan($manifest; $defaults; $name; $input; $draft):
  ($defaults + ($manifest | with_entries(select(.value != null and
    (.key | IN(component_templates[])))))) as $templates |
  {name:$name,input:$input,templates:$templates,data:{},fields:($manifest | component_inputs),
   draft:($draft + {user_text:render_template($templates.user_text; $name; $input; {}; {})} +
     ($manifest | with_entries(select(.key == "user_preview_lines"))))};

# One fd 3 line applied to $component, or null when any part is invalid.
def component_update($component):
  if type == "object" then . else {"": null} end |
  with_entries(select(.key | IN("action","argv","profile","reason"))) as $control |
  if ((keys - component_templates - ($control | keys) - ["state","data"]) | length == 0) and
    ($control == {} or ($control | component_action($component.actions // []))) and
    ((has("state") | not) or (.state | type == "array" and
      all(.[]; type == "object" and ({type:"state"} + . | canonical_state)))) and
    ((has("data") | not) or (.data | type == "object" and
      all(keys[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) and all(.[]; type == "string"))) and
    all(component_templates[] as $key | select(has($key)) | .[$key];
      component_template($component.fields))
  then
    ($component.data + (.data // {})) as $data |
    ($component.templates + with_entries(select(.key | IN(component_templates[])))) as $templates |
    {states:[.state[]? | {type:"state"} + .], control:$control,
     component:($component + {data:$data,templates:$templates,
       draft:($component.draft + {user_text:render_template($templates.user_text;
         $component.name; $component.input; {}; $data)})})}
  else null end;

# The presentation an outcome settles to, without empty texts.
def component_texts($component; $outcome):
  def render($template): render_template($template; $component.name; $component.input;
    $outcome.output; $component.data);
  $component.templates as $templates |
  ($component.draft | with_entries(select(.key == "user_preview_lines"))) +
  ({user_text:render(if $outcome.ran then $templates.user_text_done
      else $templates.user_text_skipped end),
    model_text:render($templates.model_text)} | with_entries(select(.value != "")));
