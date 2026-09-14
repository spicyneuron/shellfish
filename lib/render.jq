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

def render_script_identity:
  split("/") |
  if .[-1] == "run" then .[-2] else .[-1] end;

def render_input:
  . as $input |
  {input:($input | render_value)} +
  ($input | if type == "object" then
    with_entries(.key = "input." + .key | .value |= render_value)
  else {} end);

def default_tool_templates:
  {render:{
    user_before:"${script}\n${input}",
    user_after:"${script}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
    model_after:"${output.stdout}${output.stderr}\nexit ${output.exit_code}"
  },permission_preview:"${input}"};

def render_tool_templates:
  . as $render |
  ([$render.tools[] | select(.name == $render.name) |
    .manifest | {render,permission_preview}][0] //
    default_tool_templates);

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

def render_script_identity_start:
  if .template | contains("${script}") then
    . as $render |
    {template:($render.template | split("${script}")[0]),script:$render.script,
      input:$render.input,output:$render.output} | render_script | length
  else -1 end;

def render_script_view:
  . as $render |
  {text:($render | render_script),
   identity_start:($render | render_script_identity_start)};

# A call or activity record carries no captured output; a result carries its own.
def render_output:
  if has("stdout") then . else null end;

def render_tool_spec(channel):
  .record as $record |
  {template:({tools:.tools,name:$record.name} | render_tool_templates | channel),
   script:$record.name,
   input:($record.input | del(.request_sandbox_bypass, .sandbox_bypass_reason)),
   output:($record | render_output)};

def render_tool_before_view:
  render_tool_spec(.render.user_before) | render_script_view;

def render_tool_after_view:
  render_tool_spec(.render.user_after) | render_script_view;

def render_tool_model:
  render_tool_spec(.render.model_after) | render_script;

def render_tool_permission:
  render_tool_spec(.permission_preview) | render_script;

def default_hook_render:
  {user_before:"",user_after:"",model_after:"${output.stdout}"};

def render_hook_templates:
  . as $render |
  ([$render.hooks[$render.hook][]? |
    select(.command == $render.command) |
    .render][0] // default_hook_render);

def render_hook_spec(channel):
  .record as $record |
  {template:({hooks:.runtime.harness,hook:$record.hook,command:$record.script} |
     render_hook_templates | channel),
   script:($record.script | render_script_identity),
   input:$record.input,
   output:($record | render_output)};

def render_hook_before_view:
  render_hook_spec(.user_before) | render_script_view;

def render_hook_after_view:
  render_hook_spec(.user_after) | render_script_view;

def render_hook_model:
  render_hook_spec(.model_after) | render_script;
