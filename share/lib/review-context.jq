  def clip($cap):
    if length > $cap then .[:$cap] + "\n[\(length - $cap) characters truncated]" else . end;
  def clip_results:
    reduce .[] as $record ({age:0,out:[]};
      if $record.type == "tool_result" then
        ([512, 8192 / pow(2; .age)] | max | floor) as $cap |
        .out += [$record |
          if has("model_content") then
            .model_content |= map(if .type == "text" then .text |= clip($cap) else . end)
          else . end] |
        .age += 1
      else .out += [$record] end) | .out;
  def bytes: tojson | utf8bytelength;
  def omit_images: map(if .type == "image" then {type:"text",text:"[image omitted]"} else . end);
  .[0] as $header |
  [.[1:][] |
    select(.type != "state_update") |
    select(.type != "hook_result" or has("model_content") or has("action")) |
    (if .type == "error" then . else del(.user_text, .user_preview_lines) end) |
    if .type == "assistant" then
      del(.usage) | .content |= map(select(.type != "reasoning"))
    elif .type == "user" then .content |= omit_images
    elif (.type == "tool_result" or .type == "hook_result") and has("model_content") then
      .model_content |= omit_images
    else . end
  ] as $timeline |
  ($timeline | map(.type) | index("user")) as $first_user |
  ($timeline | map(.type) | rindex("user")) as $last_user |
  select($first_user != null) |
  ({
    system_message:$header.profile.system[0].text,
    startup_context:$timeline[:$first_user + 1],
    latest_user_message:(if $last_user > $first_user then $timeline[$last_user] else null end)
  } | with_entries(select(.value != null)) + {recent_timeline:[]} + $target) as $pinned |
  (($system | utf8bytelength) + ($pinned | bytes)) as $size |
  if $size > $budget then "" | halt_error(3) else . end |
  # Each admitted record adds its bytes and, after the first, a comma.
  (reduce ($timeline[$last_user + 1:] | reverse | clip_results)[] as $record
    ({size:$size,timeline:[],full:false};
      if .full then . else
        (.size + ($record | bytes) + (if .timeline == [] then 0 else 1 end)) as $next |
        if $next > $budget then .full = true
        else .size = $next | .timeline = [$record] + .timeline end
      end)) as $admitted |
  $pinned | .recent_timeline = $admitted.timeline
