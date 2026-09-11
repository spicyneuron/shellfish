emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# The call awaiting its durable result. Its id is validation data, not a key.
typeset -g SF_PRESENT_TOOL_CALL=''

sf_tui_tool_pending() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  (( index )) && [[ $SF_PRESENT_NODE_TYPE[index] == tool_result &&
    $SF_PRESENT_NODE_STATE[index] == open ]]
}

# A call is appended at its execution point, so its result formatter follows it
# immediately and stays pending until that result arrives.
sf_tui_tool_call() {
  local id=$1 name=$2 content=${3-} summary=${4-} format=${5:-json}
  sf_tui_activity_stop || return 1
  sf_tui_section agent || return 1
  sf_tui_add tool_call agent "$name" "$content" || return 1
  SF_PRESENT_NODE_META[REPLY]=$summary
  SF_PRESENT_NODE_FORMAT[REPLY]=$format
  sf_tui_add tool_result agent '' '' open || return 1
  SF_PRESENT_TOOL_CALL=$id
}

sf_tui_tool_result() {
  local id=$1 code=${2-} content=${3-} format=${4-} meta=${5-} sandbox=${6-}
  integer index=${#SF_PRESENT_NODE_TYPE}
  sf_tui_tool_pending && [[ $id == "$SF_PRESENT_TOOL_CALL" ]] || return 1
  sf_tui_append $index "$content" || return 1
  SF_PRESENT_NODE_STATUS[index]=$code
  SF_PRESENT_NODE_FORMAT[index]=$format
  SF_PRESENT_NODE_META[index]=$meta
  SF_PRESENT_NODE_SANDBOX_DENIAL[index]=$sandbox
  SF_PRESENT_TOOL_CALL=''
  sf_tui_close $index
}

# Annotates the pending result while the client answers, and reports whether a
# result was there to annotate.
sf_tui_tool_permission() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  REPLY=0
  sf_tui_tool_pending || return 0
  sf_tui_safe "$1"
  SF_PRESENT_NODE_BODY[index]=$REPLY
  SF_PRESENT_NODE_STATUS[index]=permission
  REPLY=1
}

sf_tui_tool_permission_clear() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  sf_tui_tool_pending && [[ $SF_PRESENT_NODE_STATUS[index] == permission ]] || return 0
  SF_PRESENT_NODE_BODY[index]=''
  SF_PRESENT_NODE_STATUS[index]=''
}

# A failed turn settles its pending result where the tool stopped.
sf_tui_tool_abandon() {
  integer index=${#SF_PRESENT_NODE_TYPE}
  sf_tui_tool_pending || return 0
  SF_PRESENT_TOOL_CALL=''
  sf_tui_close $index
}

# The notes trailing a completed tool result, in transcript order.
sf_tui_result_notes() {
  integer node=$1
  local code=$SF_PRESENT_NODE_STATUS[node]
  local -a notes=()
  [[ -z $code || $code == hidden ]] || notes+=( "exit $code" )
  [[ -z $SF_PRESENT_NODE_SANDBOX_DENIAL[node] ]] || notes+=( 'sandbox denial detected' )
  REPLY=${(j: · :)notes}
}

sf_tui_tool_preview_tail() {
  integer node=$1 hidden=$2
  local state=$SF_PRESENT_NODE_STATE[node] body=$SF_PRESENT_NODE_BODY[node]
  local notes tokens

  REPLY=''
  if [[ $SF_PRESENT_NODE_TYPE[node] == tool_call ]]; then
    (( ! hidden )) || REPLY='│ …'
    return
  fi
  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}
  sf_tui_token_count "$body"
  tokens=$REPLY
  REPLY=''
  if [[ $state == open ]]; then
    [[ $SF_PRESENT_NODE_STATUS[node] != permission ]] || return 0
    if (( hidden )); then
      REPLY="  … ~$tokens tokens $SF_PRESENT_ACTIVITY"
    else
      REPLY="╰ $SF_PRESENT_ACTIVITY"
    fi
    return
  fi
  sf_tui_result_notes $node
  notes=$REPLY
  REPLY=''
  (( ! hidden )) || REPLY="  … ~$tokens tokens"
  if [[ -n $notes ]]; then
    if [[ -n $REPLY ]]; then
      REPLY+=" · $notes"
    elif [[ -z $body ]]; then
      REPLY="╰ $notes"
    else
      REPLY="  $notes"
    fi
  elif [[ -z $body ]]; then
    REPLY='╰'
  fi
}

# Populate the active row walker's layout fields for one tool formatter.
sf_tui_tool_layout() {
  integer formatter=$1

  decorated=1
  previewed=1
  leading=${body%%[!$'\n']*}
  source_base=${#leading}
  body=${body#"$leading"}
  body=${body%"${body##*[!$'\n']}"}
  if [[ $type == tool_call ]]; then
    preview=$SF_PRESENT_PREVIEW_TOOL_CALL
    head="⛭ $heading"
    [[ -z $SF_PRESENT_NODE_META[formatter] ]] || head+=" · $SF_PRESENT_NODE_META[formatter]"
    value_start=2
    value_stop=$(( value_start + ${#heading} ))
    text=$head
    if [[ $preview == 0 ]]; then
      collapsed=1
    elif [[ -n $body ]]; then
      text+=$'\n'$body
    fi
    if (( formatter != 1 || SF_PRESENT_PREFIX_VISIBLE )); then
      text=$'\n'$text
      (( value_start++, value_stop++ ))
    fi
  else
    # A result continues its call's block, so it draws no heading and no leading
    # blank row. Its rows start at the body, under the closing rail.
    preview=$SF_PRESENT_PREVIEW_TOOL_RESULT
    [[ $SF_PRESENT_NODE_META[formatter] != full ]] || preview=full
    if [[ $preview == 0 ]]; then
      collapsed=1
      text='╰'
      [[ -z $body ]] || text+=' …'
      if [[ $state == open ]]; then
        text+=" $SF_PRESENT_ACTIVITY"
        withhold_all=1
      else
        sf_tui_result_notes $formatter
        [[ -z $REPLY ]] || text+=" · $REPLY"
      fi
      if [[ -n $body ]]; then
        clamp_start=2
        clamp_stop=${#text}
      fi
    else
      text=$body
      if [[ $SF_PRESENT_NODE_STATUS[formatter] == permission ]]; then
        withhold_all=1
      elif [[ $state == open && -z $body ]]; then
        sf_tui_tool_preview_tail $formatter 0
        activity=1
        activity_text=$REPLY
      fi
    fi
  fi
  if (( ! collapsed && ${#body} )); then
    content_start=$(( ${#text} - ${#body} ))
    content_end=${#text}
    body_start=$content_start
    body_end=$content_end
  fi
}
