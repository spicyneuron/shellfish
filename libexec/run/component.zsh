emulate -R zsh
setopt no_aliases no_multios pipe_fail

sf_run_component_update() {
  sf_jq_fields -cn --arg raw "$1" --arg lifecycle "$2" --argjson data "$3" \
    --argjson templates "$4" --argjson fields "$5" --argjson preview "$6" \
    --arg name "$7" --argjson input "$8" --argjson draft "$9" '
      include "lib/fields";
      include "lib/profile";
      include "libexec/run/component";
      ($raw | try fromjson catch null |
        component_update(if $lifecycle == "" then null else $lifecycle end;
          $fields; $data; $templates; $name; $input; $preview; $draft)) as $update |
      if $update == null then entry("valid"; "false")
      else
        entry("valid"; "true"),
        entry("states"; [$update.states[] | tojson] | join("\n")),
        entry("data"; $update.data | tojson),
        entry("templates"; $update.templates | tojson),
        entry("draft"; $update.draft | tojson),
        entry("action"; $update.control.action // ""),
        entry("reason"; $update.control.reason // ""),
        entry("payload"; $update.control | (.argv // .profile) |
          if . == null then "" else tojson end)
      end,
      ("ok" | field)
    '
}

sf_run_component_bound() {
  local source=$1 destination=$2
  integer limit=$3 bytes room
  local marker=$'[output truncated]\n'
  bytes=$(wc -c <"$source") || return
  if (( bytes <= limit )); then
    cat "$source" >"$destination"
  elif (( limit <= ${#marker} )); then
    print -rn -- "${marker[1,limit]}" >"$destination"
  else
    room=$(( limit - ${#marker} ))
    print -rn -- "$marker" >"$destination" && tail -c "$room" "$source" >>"$destination"
  fi
}
