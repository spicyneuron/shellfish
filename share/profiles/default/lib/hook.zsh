# fd 3 output for bundled hooks.

# Show TEXT as the hook's live progress. Progress claims the user text, so a
# hook that shows it must clear it before exiting or finalize its own text.
sf_hook_draft() {
  jq -cn --arg text "$1" '{user_text:$text}' >&3
}

# Settle TEXT for the user alone, replacing any progress.
sf_hook_notice() {
  jq -cn --arg text "$1" '{user_text:$text,finalize:true}' >&3
}

# Settle one result: the user sees USER and the model sees MODEL as context
# from NAME. EXTRA is an optional JSON object merged into the line.
sf_hook_context() {
  local name=$1 user=$2 model=$3 extra=${4:-null}
  jq -cn --arg name "$name" --arg user "$user" --arg model "$model" \
    --argjson extra "$extra" '
    {user_text:$user,
     model_text:("<context script=\"" + $name + "\">\n" + $model +
       (if $model | endswith("\n") then "" else "\n" end) + "</context>"),
     finalize:true} +
    ($extra // {})
  ' >&3
}
