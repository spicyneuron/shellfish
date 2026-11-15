# Core-assigned IDs identify dialogue independently of notices and rendering.
# END is the exclusive record boundary after the section's last record.
def sections:
  . as $records |
  reduce range(1; length) as $i ([];
    $records[$i] as $record |
    if $record.section == null then .
    else
      (if .[-1].id == $record.section then .
       else . + [{id:$record.section, role:(if $record.type == "user" then "user" else "agent" end),
         prompt:null, texts:[]}] end) |
      .[-1].end = ($i + 1) |
      if $record.type == "user" then
        .[-1].prompt = $i |
        .[-1].texts += [[$record.content[] | select(.type == "text") | .text] | join("")]
      elif $record.type == "assistant" then
        .[-1].texts += [$record.content[] | select(.type == "text") | .text]
      else . end
    end);
