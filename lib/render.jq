def render_template_variables:
  [scan("\\$\\{([^{}]+)\\}")[0]];

def render_template_valid:
  .template as $template |
  .variables as $variables |
  ($template | type == "string" and (index("\u0000") | not) and
    (gsub("\\$\\{[^{}]+\\}"; "") | index("${") | not) and
    (render_template_variables |
      all(.[]; . as $name | $variables | index($name) != null)));

def render_template:
  .template as $template |
  .variables as $variables |
  if ({template:$template,variables:($variables | keys)} | render_template_valid) and
      ($template | all(render_template_variables[];
        . as $name | $variables[$name] | type == "string")) then
    $template | gsub("\\$\\{(?<name>[^{}]+)\\}"; $variables[.name])
  else error("invalid render template") end;

def render_value:
  if . == null then ""
  elif type == "string" then .
  else tojson end;

def render_input:
  . as $input |
  {input:($input | render_value)} +
  ($input | if type == "object" then
    with_entries(.key = "input." + .key | .value |= render_value)
  else {} end);

def render_script:
  . as $render |
  ({script:$render.script} + ($render.input | render_input) +
    (if $render.output == null then {}
     else {
       "output.stdout":$render.output.stdout,
       "output.stderr":$render.output.stderr,
       "output.exit_code":($render.output.exit_code | tostring)
     } end)) as $variables |
  {template:$render.template,variables:$variables} | render_template;

def default_hook_render:
  {user_before:"",user_after:"",model_after:"${output.stdout}"};

def default_tool_render:
  {user_before:"${script}\n${input}",
   user_after:"${script}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
   model_after:"${output.stdout}${output.stderr}\nexit ${output.exit_code}",
   permission_preview:"${input}"};

def tool_render($tools; $name):
  ([$tools[] | select(.name == $name) | .manifest |
    .render + {permission_preview}][0] // default_tool_render);

# Bypass fields are permission plumbing, never part of what a call displays.
def render_tool($render; $name; $input; $output):
  {render:($render // default_tool_render),name:$name,
   input:($input | del(.request_sandbox_bypass, .sandbox_bypass_reason)),
   output:$output};

# One renderer for hooks and tools: every declared channel, substituted once
# against the execution's own name, input, and settled output.
def render_execution:
  . as $execution |
  reduce ($execution.render | keys_unsorted[]) as $channel ({};
    .[$channel] = ({template:$execution.render[$channel],script:$execution.name,
      input:$execution.input,output:$execution.output} | render_script));
