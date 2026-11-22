sf_command_usage() {
  jq -er --arg name "$1" '
    .[] | select(.name == $name) |
    "usage: /" + .name + (if .arguments then " " + .arguments else "" end)
  ' <<<"$SHELLFISH_COMMANDS" >&2
}
