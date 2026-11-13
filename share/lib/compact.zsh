# Shared boundaries and child-session handoff for bundled compaction commands.

# Report MESSAGE and finish without a handoff, keeping the source session.
sf_compact_fail() {
  print -ru2 -- "$1"
  exit 0
}

# {start, cut}: the first turn's index and the first recent turn's index.
sf_compact_split() {
  jq -ces '
    . as $records |
    def turn_start($index):
      if $index > 1 and ($records[$index - 1] |
          .type == "state_update" or .type == "error" or
          (.type == "hook_result" and
            (.lifecycle == "user_prompt_submit" or .lifecycle == "stop")))
      then turn_start($index - 1) else $index end;
    def text_bytes:
      (if .type == "user" or .type == "assistant" then
         [.content[] | if .type == "tool_call" then (.input | tojson)
           else .text // empty end]
       elif .type == "tool_result" then
         if has("model_content") then [.model_content[] | .text // empty]
         else [.model_text // ""] end
       elif .type == "hook_result" then [.model_text // ""]
       else [] end) | map(utf8bytelength) | add // 0;
    [to_entries[] | select(.value.type == "user") | .key | turn_start(.)] as $turns |
    select(($turns | length) > 0 and any(.[]; .type == "assistant")) |
    [range($turns | length) as $index |
      $records[$turns[$index]:$turns[$index + 1]] | map(text_bytes) | add // 0] as $sizes |
    # Keep the newest turns that fit the budget, and always the latest turn.
    (first(range(($sizes | length) - 1; 0; -1) as $index |
      select(($sizes[$index - 1:] | add) > 81920) | $index) // 0) as $keep |
    {start:$turns[0],cut:$turns[$keep]}
  ' "$SHELLFISH_SESSION"
}

sf_compact_handoff() {
  local transcript=$1 kind=$2 draft=${3-} created prepared base candidate
  local -a argv
  integer suffix=1
  created=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  prepared="$SHELLFISH_TURN_STATE/compact-child.jsonl"
  # Source usage measured a different context and cannot budget the child.
  jq -c --arg created "$created" '
    if .type == "session" then .created=$created
    elif .type == "assistant" then del(.usage) else . end
  ' "$transcript" >"$prepared" || return 1
  base=${SHELLFISH_SESSION%.jsonl}
  base=${base%_compact_tools(|_<->)}
  base=${base%_compact(|_<->)}
  candidate="${base}_${kind}.jsonl"
  while true; do
    if (umask 077; setopt no_clobber; cat -- "$prepared" >"$candidate") 2>/dev/null; then
      break
    fi
    [[ -e $candidate || -L $candidate ]] || return 1
    candidate="${base}_${kind}_${suffix}.jsonl"
    (( suffix++ ))
  done
  argv=( "$SHELLFISH_EXECUTABLE" --session "$candidate" )
  [[ -z $draft ]] || argv+=( --draft "$draft" )
  jq -cn '$ARGS.positional | {action:"handoff",argv:.}' --args -- "${argv[@]}" >&3
}
