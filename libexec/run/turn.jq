# The turn's reductions of its log. This is a program prelude, not a module:
# each caller appends the body it runs, because jq cannot compile a module
# definition that calls another module's non-leaf definition, and compiles
# only the definitions a body reaches.

include "lib/fields";
include "lib/profile";
include "lib/session";
include "lib/backend";
include "libexec/run/component";

# Model-facing tool definitions, with the sandbox-bypass fields a call may use.
def model_tools($profile; $tools):
  [$tools[] |
    .manifest as $manifest |
    (($profile.sandbox.enabled and $manifest.sandbox and
      ($manifest.allow_sandbox_bypass // false))) as $bypass |
    {name,description:($manifest.description +
      if $profile.sandbox.enabled and $manifest.sandbox
      then "\n\nThis tool runs under its package sandbox policy."
      else "\n\nSandboxing is disabled; this tool runs with the current user permissions." end +
      if .name == "shell" and $bypass
      then "\n\nWhen requesting an unsandboxed command, keep it to one logical operation. Split multi-step or compound commands across calls so each approval is easy to review."
      else "" end),
     input_schema:($manifest.input_schema |
       if $bypass then
         .properties.request_sandbox_bypass={type:"boolean",description:"Request approval to run without the sandbox"} |
         .properties.sandbox_bypass_reason={type:"string",minLength:1,
           description:"Explain why this tool call must run outside the sandbox"} |
         .allOf=((.allOf // []) + [{
           if:{properties:{request_sandbox_bypass:{const:true}},required:["request_sandbox_bypass"]},
           then:{required:["sandbox_bypass_reason"]}}])
       else . end)}];

# Everything execution and settlement need for one call.
def tool_plan($profile; $tools; $call; $turn; $max_capture):
  $call.id as $id | $call.name as $name | $call.input as $input |
  [$tools[] | select(.name == $name)][0] as $tool |
  ($tool.manifest // {}) as $manifest |
  (if $tool == null or ($profile.sandbox.enabled | not) then {decision:"none"}
   elif (($input.request_sandbox_bypass // false) | type) != "boolean" then
     {decision:"deny",reason:"sandbox bypass is not allowed"}
   elif ($input.request_sandbox_bypass // false) == false then {decision:"none"}
   elif ($tool.manifest.allow_sandbox_bypass // false) != true then
     {decision:"deny",reason:"sandbox bypass is not allowed"}
   elif ($input.sandbox_bypass_reason? | type) != "string" or
       $input.sandbox_bypass_reason == "" then
     {decision:"failure",reason:"sandbox bypass reason is required"}
   else {decision:"request",reason:$input.sandbox_bypass_reason} end) as $permission |
  ($profile.sandbox.enabled and ($manifest.sandbox // false) and
    (($input.request_sandbox_bypass // false) | not)) as $sandboxed |
  {id:$id, name:$name, input:$input,
   request:{turn_id:$turn,tool_name:$name,tool_use_id:$id,tool_input:$input},
   component:component_plan(
     (if $sandboxed then $manifest else
       $manifest |
       .user_text=(.user_text_unsandboxed // .user_text) |
       .user_text_done=(.user_text_done_unsandboxed // .user_text_done)
     end);
     {user_text:"${name} ${input}",
      user_text_done:"${name} ${input}\n${output.stdout}${output.stderr}",
      user_text_skipped:"${name} ${input}\n${output.stderr}",
      model_text:"${output.stdout}${output.stderr}"}; ($manifest | tool_inputs); $name; $input;
     {type:"_draft",id:$id,name:$name}),
   decision:$permission.decision,
   permission_reason:($permission.reason // ""),
   permission_preview:render_template($manifest.user_permission // "${input}"; $name; $input; {}; {}),
   executable:($tool.command // ""),
   environment:(($tool.manifest.environment // []) | join(" ")),
   max_capture:($manifest.max_capture_bytes // $max_capture),
   execution_input:($input | del(.request_sandbox_bypass,.sandbox_bypass_reason)),
   sandbox:$sandboxed,
   read_paths:($profile.sandbox.read | join("\n")),
   write_paths:($profile.sandbox.write | join("\n"))};

def tool_refusal($reason; $exit_code):
  {output:{stdout:"",stderr:$reason,exit_code:$exit_code},ran:false};

def tool_result($component; $outcome; $request):
  {type:"tool_result",id:$request.tool_use_id,name:$request.tool_name,
   input:$request.tool_input,exit_code:$outcome.output.exit_code} +
    component_texts($component; $outcome) |
  if canonical_tool_result then . else error("invalid tool result") end;

# Results for every pending call. The ACTIVE call settles with what it already
# sent; later calls settle with REASON.
def settled_calls($state; $profile; $tools; $turn; $max_capture; $active; $reason):
  $state.calls | to_entries[] |
  tool_plan($profile; $tools; .value; $turn; $max_capture) as $plan |
  if .key == 0 and $active != null then
    tool_result($active; tool_refusal("tool call interrupted"; 126); $plan.request)
  else tool_result($plan.component; tool_refusal($reason; 126); $plan.request) end;

# The parsed records of a complete session file read as one raw string.
def session_records:
  split("\n") as $lines |
  if $lines[-1] != "" or ($lines | length) < 2 or any($lines[0:-1][]; length == 0) then
    error("incomplete session")
  else $lines[0:-1] | map(fromjson) end |
  if .[0] | canonical_session_header then . else error("invalid session header") end;

def value: if type == "string" then . else tojson end;

# What a run needs from its session before the turn begins.
def opened($records; $share; $home):
  ($records[0] | header_expand($share; $home)) as $header |
  entry("profile"; $header.profile | tojson),
  entry("model"; $header.model | tojson),
  entry("cwd"; $header.cwd),
  entry("turn_id"; [$records[1:][] | select(.type == "user")] | length + 1 | tostring),
  entry("hook_id";
    [$records[1:][] | select(.type == "hook_result") | .id | tonumber] |
    ((max // 0) + 1) | tostring),
  entry("pending"; $records[1:] | session_state | .next != "user" | tostring);

# The log's next effect: request, tool, or user once the latest response called
# nothing.
def step($records; $share; $home; $tools; $max_capture):
  ($records[0] | header_expand($share; $home)) as $header |
  ($records[1:] | session_state) as $state |
  ([$records[1:][] | select(.type == "user")] | length) as $turn |
  entry("requests"; $state.requests | tostring),
  if $state.next == "tool_result" then
    entry("next"; "tool"),
    entry("call_index"; $state.call_total - ($state.calls | length) + 1 | tostring),
    (tool_plan($header.profile; $tools; $state.calls[0]; $turn; $max_capture) |
      to_entries[] | entry(.key; .value | value))
  # Stop feedback continues the turn with another request.
  elif $state.next == "assistant" or any($state.context[]; .lifecycle? == "stop") then
    (backend_adapter_request($header.model; ($header.profile.system[0].text // "");
      ($state | state_messages); model_tools($header.profile; $tools)) //
      error("cannot prepare provider request")) as $request |
    entry("next"; "request"),
    entry("request"; $request | tojson),
    entry("adapter"; $header.model.adapter),
    entry("context_window"; $header.model | has("context_window") | tostring)
  else
    ([$records[] | select(.type == "assistant")] | last) as $response |
    entry("next"; "user"),
    entry("response"; $response | tojson),
    entry("text";
      [$response.content[]? | select(.type == "text") | .text] | join("") | sub("\n+$"; ""))
  end;

# Any partial response and a result for every pending call, then the error.
def settle($log; $share; $home; $tools; $max_capture; $active; $partial; $reason; $message):
  (($partial | backend_delta_response),
   (($log | session_records) as $records |
     settled_calls($records[1:] | session_state;
       $records[0] | header_expand($share; $home) | .profile; $tools;
       [$records[1:][] | select(.type == "user")] | length; $max_capture; $active; $reason)),
   {type:"error",user_text:$message}) | tojson | field;
