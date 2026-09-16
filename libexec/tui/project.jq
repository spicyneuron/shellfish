# Live core events and loaded durable records become one presentation action
# vocabulary. Actions are arrays of strings; the first element is the type.
# $mode is the starting record policy and $window the known context window.

def compact_tokens:
  if . < 1000 then tostring
  elif . < 10000 then
    (((. / 100 | round) / 10) | tostring | sub("\\.0$"; "")) + "k"
  elif . < 999500 then ((. / 1000 | round) | tostring) + "k"
  elif . < 10000000 then
    (((. / 100000 | round) / 10) | tostring | sub("\\.0$"; "")) + "m"
  else ((. / 1000000 | round) | tostring) + "m"
  end;

def usage_text($window):
  (.input_tokens | compact_tokens) + " ↑" +
  (if has("cached_tokens") and .input_tokens > 0 then
     " " + ((.cached_tokens * 100 / .input_tokens) | round | tostring) + "% ⦿"
   else "" end) +
  " " + (.output_tokens | compact_tokens) + " ↓" +
  (if $window == null then ""
   else " " + ((.input_tokens * 100 / $window) | round | tostring) +
     "% of " + ($window | compact_tokens) + " ◔"
   end);

def usage_actions($window):
  if has("usage") then
    [["usage", (.usage | usage_text($window)),
      (.usage.reasoning_tokens? // "" | tostring)]]
  else [] end;

def identity: ((.backend.name // "?") + "/" + (.profile.request.model // "?"));

def hook_previews($runtime; $lifecycle):
  reduce $runtime.harness[$lifecycle][]? as $hook ({};
    .[$hook.command] = ($hook.render.preview_lines // "default"));

def runtime_previews:
  . as $runtime |
  {tools:(reduce $runtime.harness.tools[]? as $tool ({};
      .[$tool.name] = ($tool.manifest.render.preview_lines // "default"))),
   hooks:(reduce ["session_start", "user_prompt_submit", "permission_request",
      "pre_tool_use", "post_tool_use", "stop"][] as $lifecycle ({};
      .[$lifecycle] = hook_previews($runtime; $lifecycle)))};

def runtime_actions:
  [["runtime", identity, (.profile.context_window // "" | tostring),
    (runtime_previews | tojson)]];

def tool_preview($previews; $name):
  $previews.tools[$name] // "default";

def hook_preview($previews; $lifecycle; $executable):
  $previews.hooks[$lifecycle][$executable] // "default";

# Context and notice select presentation styling; their manifests select the
# preview policy independently.
def hook_class: if (.model_text // "") == "" then "notice" else "context" end;
# Model-only results show attribution without exposing model context.
def result_text:
  if (.user_text // "") != "" then .user_text
  elif (.model_text // "") != "" then .name
  else "" end;

def message_actions($role; $text):
  if ($text | test("[^\n]")) then
    [["message_start", $role], ["message_delta", "0", "text", $text, ""],
     ["message_end"]]
  else [] end;

# A response replays as the ordered blocks the live stream already showed.
def response_actions:
  . as $response |
  (.content | to_entries) as $blocks |
  ([$blocks[] | select(.value.type == "reasoning" and
    (.value.text | test("[^\n]"))) | .key]) as $reasoning |
  [["message_start", "agent"]] +
  [$blocks[] |
    if .value.type == "text" then
      ["message_delta", (.key | tostring), "text", .value.text, ""]
    elif .value.type == "reasoning" then
      ["message_delta", (.key | tostring), "reasoning", .value.text,
       (if ($reasoning | length) == 1 and .key == $reasoning[0] and
           ($response.usage.reasoning_tokens? != null)
        then ($response.usage.reasoning_tokens | tostring) else "" end)]
    else ["message_delta", (.key | tostring), "inert", "", ""]
    end] +
  [["message_end"]];

def record_actions($mode; $window; $previews):
  if .type == "assistant" then
    (if $mode == "load" then response_actions else [] end) + usage_actions($window)
  elif .type == "user" then
    if $mode == "load" then message_actions("user"; .content[0].text) else [] end
  elif .type == "system" then
    if $mode == "load" then message_actions("system"; .content) else [] end
  elif .type == "error" then
    (.user_text | split("\n")) as $lines |
    [["error", $lines[0], ($lines[1:] | join("\n"))]]
  elif .type == "tool_result" then
    [["execution_end", .id, .name, "tool", result_text,
      (tool_preview($previews; .name) | tostring)]]
  elif .type == "hook_result" then
    [["execution_end", .id, .name, hook_class, result_text,
      (hook_preview($previews; .lifecycle; (.executable // "")) | tostring)]]
  elif .type == "session" then runtime_actions
  elif .type == "state" then []
  else error("unsupported record: " + (.type | tostring))
  end;

def event_actions($window; $previews):
  if .type == "_assistant_start" then [["message_start", "agent"]]
  elif .type == "_assistant_message_delta" then
    [["message_delta", (.index | tostring), "text", .text, ""]]
  elif .type == "_assistant_reasoning_delta" then
    [["message_delta", (.index | tostring), "reasoning", .text, ""]]
  elif .type == "_assistant_tool_call_delta" or
      .type == "_assistant_reasoning_opaque" then
    [["message_delta", (.index | tostring), "inert", "", ""]]
  elif .type == "_assistant_end" then [["message_end"]]
  elif .type == "_turn_usage" then []
  elif .type == "_tool_activity" then
    [["execution_update", .id, .name, "tool", (.user_text // ""),
      (tool_preview($previews; .name) | tostring)]]
  elif .type == "_hook_activity" then
    (hook_preview($previews; .hook; (.executable // "")) | tostring) as $preview |
    if (.user_text // "") == "" then
      [["execution_end", .id, .name, "notice", "", $preview]]
    else [["execution_update", .id, .name, "notice", .user_text, $preview]] end
  elif .type == "_tool_permission_request" then
    (.preview // "") as $preview |
    [["permission", .id, .tool.name,
      (if ($preview | length) > 1000 then $preview[0:1000] + "…" else $preview end),
      (.reason // ""), "plain"]]
  elif .type == "_handoff" then [["handoff"] + .argv]
  elif .type == "_session_update" then (.runtime | runtime_actions)
  elif .type == "_session_load" then [["session", .path]]
  else error("unsupported event: " + (.type | tostring))
  end;

def nul_safe: gsub("\u0000"; "�");

[inputs | fromjson] |
reduce .[] as $line (
  {mode: $mode, window: (if $window == "" then null else ($window | tonumber) end),
   previews: $previews, actions: []};
  . as $state |
  ($line |
    if (.type // "" | startswith("_")) then event_actions($state.window; $state.previews)
    else record_actions($state.mode; $state.window; $state.previews) end) as $emitted |
  .actions += $emitted |
  if $line.type == "_session_load" then .mode = "load"
  elif $line.type == "_session_update" then
    .window = ($line.runtime.profile.context_window // null) |
    .previews = ($line.runtime | runtime_previews)
  elif $line.type == "session" then
    .window = ($line.profile.context_window // null) | .previews = ($line | runtime_previews)
  else . end
) |
# Fields are NUL-joined and each action ends with a record separator.
.actions[] |
if any(.[]; type != "string") then error("invalid action field")
else ([.[] | nul_safe] | join("\u0000")), "\u001e" end
