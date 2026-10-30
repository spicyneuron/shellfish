# Numbered sections as the transcript shows them. Each section is one side's
# turn: a run of user or agent records, unbroken by another visible role.
# Visible hook output belongs to the side of its lifecycle, so command output
# rides with the user's next prompt.
def section_role:
  if .type == "user" then "user"
  elif .type == "assistant" or .type == "tool_result" then "agent"
  elif .type == "error" then "error"
  elif .type == "hook_result" and (.user_text // "") != "" then
    {session_start:"system", user_prompt_submit:"user"}[.lifecycle] // "agent"
  else null end;

# Each section lists its start index, prompt index, and copyable text.
def sections:
  . as $records |
  reduce range(1; length) as $i ({role:null, list:[]};
    ($records[$i] | section_role) as $role |
    if $role == null then .
    else
      (if $role == .role or ($role | IN("user", "agent") | not) then .
       else .list += [{role:$role, start:$i, prompt:null, texts:[]}] end) |
      .role = $role |
      if $records[$i].type == "user" then
        .list[-1].prompt //= $i |
        .list[-1].texts += [[$records[$i].content[] | select(.type == "text") | .text] | join("")]
      elif $records[$i].type == "assistant" then
        .list[-1].texts += [$records[$i].content[] | select(.type == "text") | .text]
      else . end
    end) | .list;
