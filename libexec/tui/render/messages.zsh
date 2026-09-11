emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Standalone activity runs while work is active and no content formatter is live.
sf_tui_activity_start() {
  sf_tui_add activity '' '' '' open
}

sf_tui_activity_stop() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  (( index )) && [[ $SF_PRESENT_NODE_TYPE[index] == activity &&
    $SF_PRESENT_NODE_STATE[index] == open ]] || return 0
  sf_tui_close $index orphan_section
}

sf_tui_user_message() {
  sf_tui_activity_stop || return 1
  sf_tui_section user || return 1
  sf_tui_add message user '' "$1"
}

sf_tui_system_message() {
  sf_tui_activity_stop || return 1
  sf_tui_section system || return 1
  sf_tui_add message system '' "$1"
}

sf_tui_assistant_block() {
  local source_index=$1
  integer index=${#SF_PRESENT_NODE_TYPE}

  if [[ $SF_PRESENT_ASSISTANT_INDEX != $source_index ]]; then
    if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_tui_close $index orphan_section || return 1
    fi
    SF_PRESENT_ASSISTANT_INDEX=$source_index
  fi
}

sf_tui_assistant_stream() {
  local type=$1 source_index=$2 text=${3-}
  integer index=${#SF_PRESENT_NODE_TYPE}
  sf_tui_assistant_block "$source_index" || return 1
  [[ -n $text ]] || return 0
  index=${#SF_PRESENT_NODE_TYPE}

  if (( ! index )) || [[ $SF_PRESENT_NODE_TYPE[index] != $type ||
      $SF_PRESENT_NODE_STATE[index] != open ]]; then
    if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_tui_close $index || return 1
    fi
    sf_tui_section agent || return 1
    sf_tui_add "$type" agent '' '' open || return 1
    index=$REPLY
  fi
  sf_tui_append $index "$text" || return 1
  REPLY=$index
}

sf_tui_assistant_start() {
  SF_PRESENT_ASSISTANT_INDEX=''
  sf_tui_activity_stop || return 1
  sf_tui_section agent || return 1
  sf_tui_add activity agent '' '' open
}

sf_tui_assistant_text() {
  sf_tui_assistant_stream message "$1" "$2"
}

sf_tui_reasoning() {
  integer index
  sf_tui_assistant_stream reasoning "$1" "$2" || return 1
  if [[ -n ${3-} ]]; then
    index=${#SF_PRESENT_NODE_TYPE}
    [[ $index -gt 0 && $SF_PRESENT_NODE_TYPE[index] == reasoning &&
      $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
    SF_PRESENT_NODE_META[index]=$3
  fi
}

sf_tui_assistant_end() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  SF_PRESENT_ASSISTANT_INDEX=''
  (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]] || return 0
  [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
  sf_tui_close $index orphan_section
}

sf_tui_message_preview_tail() {
  integer node=$1 hidden=$2
  local type=$SF_PRESENT_NODE_TYPE[node] state=$SF_PRESENT_NODE_STATE[node]
  local role=$SF_PRESENT_NODE_ROLE[node] body=$SF_PRESENT_NODE_BODY[node]
  local exact='' tokens

  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}
  [[ $type != reasoning ]] || exact=$SF_PRESENT_NODE_META[node]
  sf_tui_token_count "$body" "$exact"
  tokens=$REPLY
  REPLY=''
  if [[ $type == message ]]; then
    [[ $role != system || ! hidden ]] || REPLY="… ~$tokens tokens"
  elif [[ $state == open ]]; then
    if (( hidden )); then
      REPLY="  … ~$tokens tokens $SF_PRESENT_ACTIVITY"
    else
      REPLY="  $SF_PRESENT_ACTIVITY"
    fi
  elif (( hidden )); then
    REPLY="  … Thought for ~$tokens tokens."
  else
    REPLY="  Thought for ~$tokens tokens."
  fi
}

# Populate the active row walker's layout fields for one message formatter.
sf_tui_message_layout() {
  integer formatter=$1
  local role=$SF_PRESENT_NODE_ROLE[formatter]

  if [[ $type == message ]]; then
    if [[ $role != system ]]; then
      leading=${body%%[!$'\n']*}
      source_base=${#leading}
      body=${body#"$leading"}
      if [[ $body == *$'\n' ]]; then
        tail=${body##*[!$'\n']}
        body=${body%"$tail"}$'\n'
      fi
    fi
    text=$body
    if [[ $role == system ]]; then
      previewed=1
      preview=$SF_PRESENT_PREVIEW_CONTEXT
      if [[ $preview == 0 && -n $body ]]; then
        sf_tui_token_count "$body"
        text="… ~$REPLY tokens"
        collapsed=1
        clamp_start=0
        clamp_stop=${#text}
      fi
    fi
    if [[ $state == open ]]; then
      activity=1
      withhold=1
    fi
    if [[ -z $text ]] && (( ! activity )); then
      skip=1
      return
    fi
    if (( ! collapsed && ${#body} )); then
      content_start=0
      content_end=${#body}
    fi
  else
    decorated=1
    previewed=1
    preview=$SF_PRESENT_PREVIEW_REASONING
    head='✎ Reasoning'
    leading=${body%%[!$'\n']*}
    source_base=${#leading}
    body=${body#"$leading"}
    body=${body%"${body##*[!$'\n']}"}
    if [[ $preview == 0 ]]; then
      sf_tui_token_count "$body" "$SF_PRESENT_NODE_META[formatter]"
      collapsed=1
      clamp_start=0
      if [[ $state == open ]]; then
        text="✎ Thinking… $SF_PRESENT_ACTIVITY"
        withhold_all=1
      else
        text="✎ Thought for ~$REPLY tokens."
      fi
      clamp_stop=${#text}
    else
      text=$head
      [[ -z $body ]] || text+=$'\n'$body
      if [[ $state == open && -z $body ]]; then
        sf_tui_message_preview_tail $formatter 0
        if [[ -n $REPLY ]]; then
          activity=1
          activity_text=$REPLY
        fi
      fi
    fi
    if (( ! collapsed && ${#body} )); then
      content_start=$(( ${#text} - ${#body} ))
      content_end=$(( content_start + ${#body} ))
    fi
  fi

  if (( formatter != 1 || SF_PRESENT_PREFIX_VISIBLE )); then
    text=$'\n'$text
    if (( clamp_start >= 0 )); then
      (( clamp_start++, clamp_stop++ ))
    fi
    if (( content_start >= 0 )); then
      (( content_start++, content_end++ ))
    fi
  fi
  if (( previewed && ! collapsed && ${#body} )); then
    body_start=$(( ${#text} - ${#body} ))
    body_end=${#text}
  fi
}
