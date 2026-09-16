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

def render_template($template; $variables):
  $template | gsub("\\$\\{(?<name>[^{}]+)\\}"; $variables[.name]);

def render_component($render; $name; $input; $output):
  ({name:$name} + ($input | render_input) + {
    "output.stdout":$output.stdout,
    "output.stderr":$output.stderr,
    "output.exit_code":($output.exit_code | tostring)
  }) as $variables |
  $render |
  with_entries(.value = render_template(.value;$variables)) |
  with_entries(select(.value != ""));
