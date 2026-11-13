# The turn's reductions of its log. This is a program prelude, not a module:
# each caller appends the body it runs, because jq cannot compile a module
# definition that calls another module's non-leaf definition, and compiles
# only the definitions a body reaches.

include "lib/fields";
include "lib/profile";
include "lib/session";
include "lib/provider";

# The access a call requests, as {access, reason}, {problem}, or null for none.
# Models that fill every schema field send empty requests, so null, false, "",
# and an object listing nothing all mean none, whatever its reason. Domains are
# case-insensitive.
def requested_access($bypass_allowed):
  if . == null or . == false or . == "" then null
  elif type != "object" then {problem:"request_sandbox_access must be an object"}
  elif (keys - ["read", "write", "domains", "unrestricted", "reason"]) != [] then
    {problem:"request_sandbox_access only takes read, write, domains, unrestricted, and reason"}
  elif any(.read, .write, .domains; . != null and
      (type != "array" or any(.[]; type != "string" or length == 0))) then
    {problem:"request_sandbox_access read, write, and domains must be arrays of nonempty strings"}
  elif (.unrestricted // false | type) != "boolean" then
    {problem:"request_sandbox_access unrestricted must be true or false"}
  else
    ([.read, .write, .domains | .[]?] | length > 0) as $listed |
    if ($listed or .unrestricted) | not then null
    elif (.reason | type == "string" and test("\\S")) | not then
      {problem:"request_sandbox_access requires a reason"}
    elif .unrestricted then
      if $listed then {problem:"request_sandbox_access unrestricted takes no read, write, or domains"}
      elif $bypass_allowed | not then {problem:"sandbox bypass is not allowed"}
      else {access:{unrestricted:true},reason} end
    elif any(.domains[]?; sandbox_domain | not) then
      {problem:"request_sandbox_access domains must be hostnames or *.hostname"}
    else {access:{read:(.read // []),write:(.write // []),
      domains:(.domains // [] | map(ascii_downcase))},reason} end
  end;

# Everything execution and settlement need for one call.
def tool_plan($profile; $tools; $call; $turn; $max_capture):
  $call.id as $id | $call.name as $name | $call.input as $input |
  [$tools[] | select(.name == $name)][0] as $tool |
  ($tool.manifest // {}) as $manifest |
  # Hooks and the tool see the operation without the model's access request.
  ($input | del(.request_sandbox_access)) as $operation |
  ($profile.sandbox.enabled and ($manifest.sandbox // false)) as $sandboxable |
  (if $tool == null or ($sandboxable | not) then {decision:"none"}
   else $input.request_sandbox_access |
     requested_access($manifest.allow_sandbox_bypass // false) |
     if . == null then {decision:"none"}
     elif .problem then {decision:"deny",reason:.problem}
     else {decision:"request",reason,access} end
   end) as $permission |
  {id:$id, name:$name, input:$input,
   request:{turn_id:$turn,tool_name:$name,tool_use_id:$id,tool_input:$operation},
   component:{template:$manifest.user_text, input:$input,
     draft:({type:"_draft",id:$id,name:$name,
       user_text:render_template($manifest.user_text; {input:$input})} +
       ($manifest | with_entries(select(.key == "user_preview_lines"))) +
       if $permission.decision == "request" then {sandbox_access:"requested"} else {} end)},
   decision:$permission.decision,
   permission_reason:($permission.reason // ""),
   access:($permission.access // null),
   executable:($tool.command // ""),
   environment:(($tool.manifest.environment // []) | join(" ")),
   max_capture:(if $manifest.max_capture_kb then $manifest.max_capture_kb * 1024 else $max_capture end),
   execution_input:$operation,
   sandbox:($sandboxable and ($permission.access.unrestricted // false | not)),
   read_paths:($profile.sandbox.tools[$name].read // [] | join("\n")),
   write_paths:($profile.sandbox.tools[$name].write // [] | join("\n")),
   domains:($profile.sandbox.tools[$name].domains // [])};

def tool_refusal($reason; $exit_code):
  {output:{stdout:$reason,stderr:$reason,exit_code:$exit_code},ran:false};

# Model text is stdout, which leads any content parts as model content. A
# sandbox request that was never answered keeps no badge unless the tool ran,
# which implies approval.
def tool_result($component; $outcome):
  ($component.draft | del(.user_text)) + {type:"tool_result",input:$component.input,
    exit_code:$outcome.output.exit_code,
    user_text:render_template($component.template; $component + $outcome)} +
  (if ($outcome.content // []) == [] then {model_text:$outcome.output.stdout}
   else {model_content:([$outcome.output.stdout | select(. != "") |
     {type:"text",text:.}] + $outcome.content)} end) |
  if .sandbox_access != "requested" then .
  elif $outcome.ran then .sandbox_access = "approved"
  else del(.sandbox_access) end |
  with_entries(select(.value != "")) |
  if canonical_tool_result then . else error("invalid tool result") end;

# Results for every pending call. The call that was running when the turn
# ended, if ACTIVE, settles as interrupted; later calls settle with REASON,
# and their sandbox requests as cancelled.
def settled_calls($state; $profile; $tools; $turn; $max_capture; $active; $reason):
  $state.calls | to_entries[] |
  tool_plan($profile; $tools; .value; $turn; $max_capture) as $plan |
  if .key == 0 and $active then
    tool_result($plan.component; tool_refusal("tool call interrupted"; 126) | .ran = true)
  else
    tool_result($plan.component |
      if .draft.sandbox_access == "requested" then .draft.sandbox_access = "cancelled"
      else . end; tool_refusal($reason; 126))
  end;

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
  entry("user_approval_timeout"; $header.profile.sandbox.user_approval_timeout // 120 | tostring),
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
  elif $state.next == "assistant" then
    (provider_request($header.model; ($header.profile.system[0].text // "");
      ($state | state_messages); model_tools($header.profile; $tools)) //
      error("cannot prepare provider request")) as $request |
    entry("next"; "request"),
    entry("request"; $request | tojson),
    entry("provider"; $header.model.provider),
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
  (($partial | provider_delta_response),
   (($log | session_records) as $records |
     settled_calls($records[1:] | session_state;
       $records[0] | header_expand($share; $home) | .profile; $tools;
       [$records[1:][] | select(.type == "user")] | length; $max_capture; $active; $reason)),
   {type:"error",user_text:$message}) | tojson | field;
