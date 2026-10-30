# Live core events and loaded durable records become one presentation action
# vocabulary. Actions are arrays of strings; the first element is the type.
# $mode is the starting record policy, $window the known context window, and
# $drawn the readable blocks of the open live message.

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

# The provider name is its directory name.
def identity:
  ((.model.provider // "?" | split("/") | last) + "/" + (.model.request.model // "?"));

def model_actions:
  [["profile", identity, (.model.context_window // "" | tostring)]];

# Component names drop their directory prefix. A disabled sandbox has no
# grant counts.
def details_actions:
  def names(kind):
    [.profile[kind][]? | sub("^.*" + kind + "/"; "")] | join(", ");
  [["details", names("tools"), names("commands"), names("hooks")] +
    (.profile.sandbox |
      if .enabled then [.read, .write | length | tostring] else ["", ""] end)];

# A result or draft carries its own preview hint.
def preview: .user_preview_lines // "default" | tostring;

# Context and notice select presentation styling.
def hook_class: if (.model_text // "") == "" then "notice" else "context" end;
# The core marks sandbox bypass requests so that no template can hide them.
# The client draws the badge; an empty template still shows the tool name.
def result_text:
  if has("sandbox_bypass") then .user_text // .name else .user_text // "" end;
def bypass: .sandbox_bypass // "";
# A hook's deny is policy, not failure; commands deny every prompt they handle.
def failed: if .exit_code != 0 then "1" else "" end;

def message_actions($role; $text):
  if ($text | test("[^\n]")) then
    [["message_start", $role], ["message_delta", "0", "text", $text, ""],
     ["message_end"]]
  else [] end;

# Deltas join into readable blocks the way the core joins a cancelled response:
# a delta of another kind starts the next block.
def delta_kind: if .type == "_assistant_reasoning_delta" then "reasoning" else "text" end;
def draw($delta):
  ($delta | delta_kind) as $kind |
  if .[-1].type? == $kind then .[-1].text += $delta.text
  else . + [{type:$kind, text:$delta.text}] end;

# A response draws its blocks after whatever its deltas already drew. $drawn is
# null when no live message is open.
def response_actions($drawn):
  . as $response |
  [.content | to_entries[] | select(.value.type | IN("text", "reasoning")) | .key] as $readable |
  ([.content[] | select(.type == "reasoning" and (.text | test("[^\n]")))] | length) as $thoughts |
  (if $drawn == null then [["message_start", "agent"]] else [] end) +
  [.content | to_entries[] | . as $block |
    if (.value.type | IN("text", "reasoning")) then
      ($readable | index($block.key)) as $n |
      (($drawn // [])[$n].text // "") as $shown |
      (if .value.text | startswith($shown) then .value.text[($shown | length):] else "" end) as $rest |
      # A block its deltas drew completely is already on screen.
      if $n < ($drawn // [] | length) and $rest == "" then empty else
        ["message_delta", ($n | tostring), .value.type, $rest,
         (if .value.type == "reasoning" and $thoughts == 1 and (.value.text | test("[^\n]")) and
             ($response.usage.reasoning_tokens? != null)
          then ($response.usage.reasoning_tokens | tostring) else "" end)]
      end
    else ["message_delta", (.key | tostring), "inert", "", ""]
    end] +
  [["message_end"]];

def record_actions($mode; $window; $drawn):
  if .type == "assistant" then
    response_actions($drawn) + usage_actions($window)
  elif .type == "user" then
    .content[0].text as $text |
    message_actions("user"; $text) +
    # Live prompts enter history when submitted.
    if $mode == "load" and ($text | test("[^\n]")) then [["prompt", $text]] else [] end
  elif .type == "error" then
    (.user_text | split("\n")) as $lines |
    [["error", $lines[0], ($lines[1:] | join("\n"))]]
  elif .type == "tool_result" then
    [["execution_end", .id, "tool", result_text, preview, "", bypass, failed]]
  elif .type == "hook_result" then
    [["execution_end", .id, hook_class, result_text, preview,
      ({session_start:"system", user_prompt_submit:"user"}[.lifecycle] // "agent")]]
  elif .type == "session" then
    details_actions + model_actions +
    if $mode == "load" then message_actions("system"; .profile.system[0].text // "") else [] end
  elif .type == "state_update" then []
  else error("unsupported record: " + (.type | tostring))
  end;

# $drawn already includes this event.
def event_actions($window; $drawn):
  if .type == "_assistant_start" then [["message_start", "agent"]]
  elif .type | IN("_assistant_message_delta", "_assistant_reasoning_delta") then
    [["message_delta", ($drawn | length - 1 | tostring), delta_kind, .text, ""]]
  # A tool draft names its tool.
  elif .type == "_draft" then
    [["execution_update", .id, (if has("name") then "tool" else "notice" end), result_text,
      preview, bypass]]
  # The preview is deliberately truncated. Deny when it is not enough to decide;
  # review hooks receive the full input.
  elif .type == "_tool_permission_request" then
    (.tool.input | tojson) as $preview |
    [["permission", .id, .tool.name,
      (if ($preview | length) > 300 then $preview[0:300] + "…" else $preview end),
      (.reason // ""), (.timeout | tostring)]]
  elif .type == "_handoff" then [["handoff"] + .argv]
  elif .type == "_session_update" then model_actions
  elif .type == "_session_load" then [["session", .path]]
  else error("unsupported event: " + (.type | tostring))
  end;

def nul_safe: gsub("\u0000"; "�");

[inputs | fromjson] |
reduce .[] as $line (
  {mode: $mode, window: (if $window == "" then null else ($window | tonumber) end),
   drawn: $drawn, actions: []};
  . as $state |
  # A live message stays open from its start until a record or a load.
  ($line |
    if .type == "_assistant_start" then []
    elif .type | IN("_assistant_message_delta", "_assistant_reasoning_delta") then
      $state.drawn // [] | draw($line)
    elif (.type // "" | startswith("_")) and .type != "_session_load" then $state.drawn
    else null end) as $drawn |
  ($line |
    if (.type // "" | startswith("_")) then event_actions($state.window; $drawn)
    else record_actions($state.mode; $state.window; $state.drawn) end) as $emitted |
  .actions += $emitted |
  .drawn = $drawn |
  if $line.type == "_session_load" then .mode = "load"
  elif $line.type | IN("session", "_session_update") then
    .window = ($line.model.context_window // null)
  else . end
) |
# The state for the next batch leads, then fields are NUL-joined and each
# action ends with a record separator.
([.mode, (.window // "" | tostring), (.drawn | tojson)] | join("\u0000")), "\u001e",
(.actions[] |
  if any(.[]; type != "string") then error("invalid action field")
  else ([.[] | nul_safe] | join("\u0000")), "\u001e" end)
