def assemble_backend_response(valid_events; valid_message):
  select(valid_events) |
  reduce .[] as $event
    ({blocks:{}, usage:null, stop:null, valid:true};
      ($event.index? | tostring) as $index |
      if .valid | not then .
      elif $event.type == "_assistant_delta" then
        if .blocks[$index] == null then
          .blocks[$index] = {type:"text", text:$event.text}
        elif .blocks[$index].type == "text" then
          .blocks[$index].text += $event.text
        else .valid = false end
      elif $event.type == "_assistant_reasoning_delta" then
        if .blocks[$index] == null then
          .blocks[$index] = {type:"reasoning", text:$event.text}
        elif .blocks[$index].type == "reasoning" then
          .blocks[$index].text += $event.text
        else .valid = false end
      elif $event.type == "_assistant_reasoning_opaque" then
        if .blocks[$index] == null then
          .blocks[$index] = {type:"reasoning", text:"", opaque:$event.opaque}
        elif .blocks[$index].type != "reasoning" then .valid = false
        elif .blocks[$index].opaque != null and .blocks[$index].opaque != $event.opaque then
          .valid = false
        else .blocks[$index].opaque = $event.opaque end
      elif $event.type == "_assistant_tool_call_delta" then
        if .blocks[$index] == null then
          .blocks[$index] = {type:"tool_call", id:null, name:null, input_text:""}
        else . end |
        if .blocks[$index].type != "tool_call" then .valid = false
        elif ($event.id? != null and .blocks[$index].id != null and
              .blocks[$index].id != $event.id) or
             ($event.name? != null and .blocks[$index].name != null and
              .blocks[$index].name != $event.name) then .valid = false
        else
          .blocks[$index].id = ($event.id? // .blocks[$index].id) |
          .blocks[$index].name = ($event.name? // .blocks[$index].name) |
          .blocks[$index].input_text += ($event.input? // "")
        end
      elif $event.type == "_turn_usage" then .usage = ($event | del(.type))
      elif $event.type == "_assistant_response_end" then .stop = $event.stop
      else .valid = false end) |
  select(.valid) |
  . as $state |
  [.blocks | to_entries | sort_by(.key | tonumber)[] | .value |
    if .type != "tool_call" then {valid:true, content:.}
    elif $state.stop == "length" then {valid:true, content:null}
    elif $state.stop != "tool_calls" then {valid:false, content:null}
    else (.input_text | if . == "" then {} else try fromjson catch null end) as $input |
      if .id != null and .name != null and ($input | type) == "object" then
        {valid:true, content:{type, id, name, input:$input}}
      else {valid:false, content:null} end
    end] as $blocks |
  select(all($blocks[]; .valid)) |
  [$blocks[].content | select(. != null)] as $content |
  {type:"message", role:"assistant", stop:.stop, content:$content} +
    (if .usage == null then {} else {usage:.usage} end) |
  select(valid_message);
