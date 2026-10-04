include "lib/profile";
include "lib/session";

# Invocation values and initial presentation. The manifest overrides $defaults.
def component_plan($manifest; $defaults; $fields; $name; $input; $draft):
  ($defaults + ($manifest | with_entries(select(.value != null and
    (.key | IN(component_templates[])))))) as $templates |
  {name:$name,input:$input,templates:$templates,data:{},fields:$fields,
   draft:($draft + {user_text:render_template($templates.user_text; $name; $input; {}; {})} +
     ($manifest | with_entries(select(.key == "user_preview_lines"))))};

# One fd 3 line applied to $component, or null when any part is invalid. The
# caller's $rest keys pass through unvalidated.
def component_update($component; $rest):
  if type == "object" and
    ((keys - component_templates - ["state_update","data"] - $rest) | length == 0) and
    ((has("state_update") | not) or (.state_update | type == "array" and
      all(.[]; type == "object" and ({type:"state_update"} + . | canonical_state_update)))) and
    ((has("data") | not) or (.data | type == "object" and
      all(keys[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) and all(.[]; type == "string"))) and
    all(component_templates[] as $key | select(has($key)) | .[$key];
      component_template($component.fields))
  then
    ($component.data + (.data // {})) as $data |
    ($component.templates + with_entries(select(.key | IN(component_templates[])))) as $templates |
    {state_updates:[.state_update[]? | {type:"state_update"} + .],
     rest:with_entries(select(.key | IN($rest[]))),
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
