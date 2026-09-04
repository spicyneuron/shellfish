emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# The presentation transcript. Only this file mutates these arrays.
typeset -ga SF_PRESENT_NODE_TYPE=() SF_PRESENT_NODE_ROLE=()
typeset -ga SF_PRESENT_NODE_HEADING=() SF_PRESENT_NODE_BODY=()
typeset -ga SF_PRESENT_NODE_META=() SF_PRESENT_NODE_STATE=()
typeset -ga SF_PRESENT_NODE_STATUS=() SF_PRESENT_NODE_FORMAT=()
# Marks a tool result accompanied by a detected sandbox denial.
typeset -ga SF_PRESENT_NODE_SANDBOX_DENIAL=()
# A formatter enables the node frontier before body rows can flush. A negative
# frontier preserves ordinary row settlement.
typeset -ga SF_PRESENT_NODE_FRONTIER=()
typeset -gA SF_PRESENT_TOOL_HEADING=() SF_PRESENT_TOOL_CONTENT=()
typeset -gA SF_PRESENT_TOOL_SUMMARY=() SF_PRESENT_TOOL_FORMAT=()
typeset -ga SF_PRESENT_TOOL_ORDER=()
typeset -g SF_PRESENT_TOOL_CURRENT=''
typeset -g SF_PRESENT_ERROR='' SF_PRESENT_LAST_ROLE=''
typeset -gi SF_PRESENT_SECTION_ID=0

sf_chat_safe() {
  local character text=$1
  local -a characters
  REPLY=''
  characters=( ${(s::)text} )
  for character in $characters; do
    if [[ $character == $'\n' || $character == $'\t' || $character != [[:cntrl:]] ]]; then
      REPLY+=$character
    else
      REPLY+='�'
    fi
  done
}

sf_chat_reset() {
  sf_chat_drop ${#SF_PRESENT_NODE_TYPE}
  SF_PRESENT_TOOL_HEADING=()
  SF_PRESENT_TOOL_CONTENT=()
  SF_PRESENT_TOOL_SUMMARY=()
  SF_PRESENT_TOOL_FORMAT=()
  SF_PRESENT_TOOL_ORDER=()
  SF_PRESENT_TOOL_CURRENT=''
  SF_PRESENT_LAST_ROLE=''
  SF_PRESENT_SECTION_ID=0
}

sf_chat_add() {
  local type=$1 role=${2-} heading=${3-} body=${4-} state=${5:-closed}
  integer last=${#SF_PRESENT_NODE_TYPE} index
  index=$(( last + 1 ))

  if (( last )) && [[ $SF_PRESENT_NODE_STATE[last] == open ]]; then
    return 1
  fi
  sf_chat_safe "$heading"; heading=$REPLY
  sf_chat_safe "$body"; body=$REPLY
  SF_PRESENT_NODE_TYPE[index]=$type
  SF_PRESENT_NODE_ROLE[index]=$role
  SF_PRESENT_NODE_HEADING[index]=$heading
  SF_PRESENT_NODE_BODY[index]=$body
  SF_PRESENT_NODE_STATE[index]=$state
  SF_PRESENT_NODE_FRONTIER[index]=-1
  REPLY=$index
}

sf_chat_set_frontier() {
  integer index=$1 offset=$2 current
  (( index > 0 && index <= ${#SF_PRESENT_NODE_TYPE} )) || return 1
  (( offset >= 0 && offset <= ${#SF_PRESENT_NODE_BODY[index]} )) || return 1
  current=$SF_PRESENT_NODE_FRONTIER[index]
  (( current < 0 || offset >= current )) || return 1
  SF_PRESENT_NODE_FRONTIER[index]=$offset
}

sf_chat_section() {
  local role=$1 id=''
  [[ $SF_PRESENT_LAST_ROLE != $role ]] || return 0
  if [[ $role == (user|agent) ]]; then
    (( ++SF_PRESENT_SECTION_ID ))
    id=$SF_PRESENT_SECTION_ID
  fi
  sf_chat_add section "$role" "$id" || {
    [[ -z $id ]] || (( --SF_PRESENT_SECTION_ID ))
    return 1
  }
  SF_PRESENT_LAST_ROLE=$role
}

sf_chat_drop() {
  integer count=$1 total=${#SF_PRESENT_NODE_TYPE}
  (( count >= 0 && count <= total )) || return 1
  (( count )) || return 0
  sf_chat_highlight_drop $count
  if (( count == total )); then
    SF_PRESENT_NODE_TYPE=()
    SF_PRESENT_NODE_ROLE=()
    SF_PRESENT_NODE_HEADING=()
    SF_PRESENT_NODE_BODY=()
    SF_PRESENT_NODE_META=()
    SF_PRESENT_NODE_STATE=()
    SF_PRESENT_NODE_STATUS=()
    SF_PRESENT_NODE_FORMAT=()
    SF_PRESENT_NODE_SANDBOX_DENIAL=()
    SF_PRESENT_NODE_FRONTIER=()
    return 0
  fi
  SF_PRESENT_NODE_TYPE=( "${(@)SF_PRESENT_NODE_TYPE[count + 1,-1]}" )
  SF_PRESENT_NODE_ROLE=( "${(@)SF_PRESENT_NODE_ROLE[count + 1,-1]}" )
  SF_PRESENT_NODE_HEADING=( "${(@)SF_PRESENT_NODE_HEADING[count + 1,-1]}" )
  SF_PRESENT_NODE_BODY=( "${(@)SF_PRESENT_NODE_BODY[count + 1,-1]}" )
  SF_PRESENT_NODE_META=( "${(@)SF_PRESENT_NODE_META[count + 1,-1]}" )
  SF_PRESENT_NODE_STATE=( "${(@)SF_PRESENT_NODE_STATE[count + 1,-1]}" )
  SF_PRESENT_NODE_STATUS=( "${(@)SF_PRESENT_NODE_STATUS[count + 1,-1]}" )
  SF_PRESENT_NODE_FORMAT=( "${(@)SF_PRESENT_NODE_FORMAT[count + 1,-1]}" )
  SF_PRESENT_NODE_SANDBOX_DENIAL=( "${(@)SF_PRESENT_NODE_SANDBOX_DENIAL[count + 1,-1]}" )
  SF_PRESENT_NODE_FRONTIER=( "${(@)SF_PRESENT_NODE_FRONTIER[count + 1,-1]}" )
}

sf_chat_close() {
  integer index=$1 end section removed_section=0
  local body
  [[ $index == ${#SF_PRESENT_NODE_TYPE} && $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
  body=$SF_PRESENT_NODE_BODY[index]
  if [[ $SF_PRESENT_NODE_TYPE[index] == (message|reasoning) && $body != *[!$'\n']* ]]; then
    body=''
  fi
  if [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) &&
      -z $SF_PRESENT_NODE_HEADING[index] && -z $body ]]; then
    end=$(( index - 1 ))
    if [[ ${2-} == orphan_section && $index -gt 1 &&
        $SF_PRESENT_NODE_TYPE[index-1] == section ]]; then
      end=$(( end - 1 ))
      [[ -z $SF_PRESENT_NODE_HEADING[index-1] ]] || removed_section=1
    fi
    SF_PRESENT_NODE_TYPE=( "${(@)SF_PRESENT_NODE_TYPE[1,end]}" )
    SF_PRESENT_NODE_ROLE=( "${(@)SF_PRESENT_NODE_ROLE[1,end]}" )
    SF_PRESENT_NODE_HEADING=( "${(@)SF_PRESENT_NODE_HEADING[1,end]}" )
    SF_PRESENT_NODE_BODY=( "${(@)SF_PRESENT_NODE_BODY[1,end]}" )
    SF_PRESENT_NODE_META=( "${(@)SF_PRESENT_NODE_META[1,end]}" )
    SF_PRESENT_NODE_STATE=( "${(@)SF_PRESENT_NODE_STATE[1,end]}" )
    SF_PRESENT_NODE_STATUS=( "${(@)SF_PRESENT_NODE_STATUS[1,end]}" )
    SF_PRESENT_NODE_FORMAT=( "${(@)SF_PRESENT_NODE_FORMAT[1,end]}" )
    SF_PRESENT_NODE_SANDBOX_DENIAL=( "${(@)SF_PRESENT_NODE_SANDBOX_DENIAL[1,end]}" )
    SF_PRESENT_NODE_FRONTIER=( "${(@)SF_PRESENT_NODE_FRONTIER[1,end]}" )
    if (( end < index - 1 )); then
      (( ! removed_section )) || SF_PRESENT_SECTION_ID=$(( SF_PRESENT_SECTION_ID - 1 ))
      section=${SF_PRESENT_NODE_TYPE[(I)section]}
      SF_PRESENT_LAST_ROLE=${SF_PRESENT_NODE_ROLE[section]-}
    fi
    return 0
  fi
  SF_PRESENT_NODE_STATE[index]=closed
}

sf_chat_append() {
  integer index=$1
  local text=${2-}
  [[ $index == ${#SF_PRESENT_NODE_TYPE} && $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
  [[ -n $text ]] || return 0
  sf_chat_safe "$text"
  SF_PRESENT_NODE_BODY[index]+=$REPLY
}

sf_chat_stream() {
  local type=$1 text=${2-}
  integer index=${#SF_PRESENT_NODE_TYPE}
  [[ -n $text ]] || return 0

  if (( ! index )) || [[ $SF_PRESENT_NODE_TYPE[index] != $type ||
      $SF_PRESENT_NODE_STATE[index] != open ]]; then
    if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_chat_close $index || return 1
    fi
    sf_chat_section agent || return 1
    sf_chat_add "$type" agent '' '' open || return 1
    index=$REPLY
  fi
  sf_chat_append $index "$text" || return 1
  REPLY=$index
}

sf_chat_tool_open() {
  local id=$SF_PRESENT_TOOL_CURRENT
  if [[ -z $id ]]; then
    id=${SF_PRESENT_TOOL_ORDER[1]-}
    [[ -n $id ]] || return 0
  fi
  if (( ${#SF_PRESENT_NODE_TYPE} )) && [[ $SF_PRESENT_NODE_STATE[-1] == open ]]; then
    [[ -n $SF_PRESENT_TOOL_CURRENT && $SF_PRESENT_NODE_TYPE[-1] == tool_result ]] || return 1
    return 0
  fi
  sf_chat_section agent || return 1
  if [[ -z $SF_PRESENT_TOOL_CURRENT ]]; then
    sf_chat_add tool_call agent "$SF_PRESENT_TOOL_HEADING[$id]" \
      "$SF_PRESENT_TOOL_CONTENT[$id]" || return 1
    SF_PRESENT_NODE_META[REPLY]=$SF_PRESENT_TOOL_SUMMARY[$id]
    SF_PRESENT_NODE_FORMAT[REPLY]=$SF_PRESENT_TOOL_FORMAT[$id]
  fi
  sf_chat_add tool_result agent '' '' open || return 1
  SF_PRESENT_TOOL_CURRENT=$id
}

sf_chat_notice() {
  local severity=$1 heading=$2 body=${3-} state=${4:-closed}
  integer index=${#SF_PRESENT_NODE_TYPE} notice_index resume_tool=0
  if (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]]; then
    # A live notice settles in place, so its outcome replaces its own row.
    if [[ $SF_PRESENT_NODE_TYPE[index] == notice ]]; then
      sf_chat_safe "$heading"; SF_PRESENT_NODE_HEADING[index]=$REPLY
      sf_chat_safe "$body"; SF_PRESENT_NODE_BODY[index]=$REPLY
      SF_PRESENT_NODE_ROLE[index]=$severity
      [[ $state == open ]] || sf_chat_close $index || return 1
      if [[ $state != open && -n $SF_PRESENT_TOOL_CURRENT ]]; then
        notice_index=$index
        if [[ $severity == error ]]; then
          SF_PRESENT_TOOL_HEADING=()
          SF_PRESENT_TOOL_CONTENT=()
          SF_PRESENT_TOOL_SUMMARY=()
          SF_PRESENT_TOOL_FORMAT=()
          SF_PRESENT_TOOL_ORDER=()
          SF_PRESENT_TOOL_CURRENT=''
        else
          sf_chat_tool_open || return 1
        fi
        index=$notice_index
      fi
      REPLY=$index
      return 0
    fi
    if [[ $SF_PRESENT_NODE_TYPE[index] == tool_result ]]; then
      if [[ $severity == error ]]; then
        sf_chat_event tool_segment_close abandon || return 1
      else
        sf_chat_event tool_segment_close continue || return 1
        resume_tool=1
      fi
    else
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_chat_close $index || return 1
    fi
  fi
  sf_chat_add notice "$severity" "$heading" "$body" "$state" || return 1
  notice_index=$REPLY
  if (( resume_tool )) && [[ $state != open ]]; then
    sf_chat_tool_open || return 1
  fi
  REPLY=$notice_index
}

sf_chat_footer_usage() {
  SF_PRESENT_FOOTER="${SF_PRESENT_IDENTITY} · $1"
}

sf_chat_event() {
  local type=$1 first=${2-} second=${3-} third=${4-} fourth=${5-} fifth=${6-} sixth=${7-}
  integer index=${#SF_PRESENT_NODE_TYPE}

  if [[ $type == assistant && $first != *[!$'\n']* && $second != *[!$'\n']* ]]; then
    return 0
  fi

  if (( index )) && [[ $SF_PRESENT_NODE_TYPE[index] == activity &&
      $SF_PRESENT_NODE_STATE[index] == open &&
      $type == (system|user|backend_request_start|assistant|tool_call|context) ]]; then
    sf_chat_close $index || return 1
    index=${#SF_PRESENT_NODE_TYPE}
  fi

  case $type in
    system|user)
      sf_chat_section $type || return 1
      sf_chat_add message $type '' "$first"
      ;;
    backend_request_start)
      sf_chat_section agent || return 1
      sf_chat_add activity agent '' '' open
      ;;
    assistant)
      sf_chat_section agent || return 1
      if [[ $second == *[!$'\n']* ]]; then
        sf_chat_add reasoning agent '' "$second" || return 1
        SF_PRESENT_NODE_META[REPLY]=$third
      fi
      if [[ $first == *[!$'\n']* ]]; then
        sf_chat_add message agent '' "$first"
      fi
      ;;
    assistant_delta)
      sf_chat_stream message "$first"
      ;;
    assistant_reasoning_delta)
      sf_chat_stream reasoning "$first"
      ;;
    reasoning_tokens)
      if [[ -n $first && $index -gt 0 && $SF_PRESENT_NODE_TYPE[index] == reasoning &&
          $SF_PRESENT_NODE_STATE[index] == open ]]; then
        SF_PRESENT_NODE_META[index]=$first
      fi
      ;;
    assistant_commit)
      (( index )) && [[ $SF_PRESENT_NODE_STATE[index] == open ]] || return 0
      [[ $SF_PRESENT_NODE_TYPE[index] == (activity|message|reasoning) ]] || return 1
      sf_chat_close $index orphan_section
      ;;
    tool_call)
      SF_PRESENT_TOOL_HEADING[$first]=$second
      sf_chat_safe "$third"
      SF_PRESENT_TOOL_CONTENT[$first]=$REPLY
      SF_PRESENT_TOOL_SUMMARY[$first]=$fourth
      SF_PRESENT_TOOL_FORMAT[$first]=${fifth:-json}
      SF_PRESENT_TOOL_ORDER+=( "$first" )
      sf_chat_tool_open
      ;;
    tool_result)
      [[ -n ${SF_PRESENT_TOOL_HEADING[$first]+yes} ]] || return 1
      [[ $SF_PRESENT_TOOL_CURRENT == $first && $index == ${#SF_PRESENT_NODE_TYPE} &&
        $SF_PRESENT_NODE_TYPE[index] == tool_result &&
        $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
      sf_chat_append $index "$third" || return 1
      SF_PRESENT_NODE_STATUS[index]=$second
      SF_PRESENT_NODE_FORMAT[index]=$fourth
      SF_PRESENT_NODE_META[index]=$fifth
      SF_PRESENT_NODE_SANDBOX_DENIAL[index]=$sixth
      sf_chat_close $index || return 1
      unset "SF_PRESENT_TOOL_HEADING[$first]" "SF_PRESENT_TOOL_CONTENT[$first]" \
        "SF_PRESENT_TOOL_SUMMARY[$first]" "SF_PRESENT_TOOL_FORMAT[$first]"
      SF_PRESENT_TOOL_ORDER=( "${(@)SF_PRESENT_TOOL_ORDER[2,-1]}" )
      SF_PRESENT_TOOL_CURRENT=''
      sf_chat_tool_open
      ;;
    tool_segment_close)
      [[ $first == (continue|abandon) && -n $SF_PRESENT_TOOL_CURRENT &&
          $SF_PRESENT_NODE_TYPE[index] == tool_result &&
          $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
      sf_chat_close $index || return 1
      if [[ $first == abandon ]]; then
        SF_PRESENT_TOOL_HEADING=()
        SF_PRESENT_TOOL_CONTENT=()
        SF_PRESENT_TOOL_SUMMARY=()
        SF_PRESENT_TOOL_FORMAT=()
        SF_PRESENT_TOOL_ORDER=()
        SF_PRESENT_TOOL_CURRENT=''
      fi
      ;;
    tool_permission)
      REPLY=0
      if [[ -n $SF_PRESENT_TOOL_CURRENT && $SF_PRESENT_NODE_TYPE[index] == tool_result &&
          $SF_PRESENT_NODE_STATE[index] == open ]]; then
        sf_chat_safe "$first"
        SF_PRESENT_NODE_BODY[index]=$REPLY
        SF_PRESENT_NODE_STATUS[index]=permission
        REPLY=1
      fi
      ;;
    tool_permission_clear)
      if [[ $SF_PRESENT_NODE_TYPE[index] == tool_result &&
          $SF_PRESENT_NODE_STATE[index] == open &&
          $SF_PRESENT_NODE_STATUS[index] == permission ]]; then
        SF_PRESENT_NODE_BODY[index]=''
        SF_PRESENT_NODE_STATUS[index]=''
      fi
      ;;
    context)
      sf_chat_add injection system "$first" "$third" || return 1
      SF_PRESENT_NODE_META[REPLY]=$second
      ;;
    *) return 1 ;;
  esac
}

sf_chat_reload() {
  local session_path=$1 events
  local -a fields
  integer complete=0 index

  SF_PRESENT_ERROR=''
  [[ -f $session_path && ! -L $session_path ]] || {
    SF_PRESENT_ERROR="invalid session path: $session_path"
    return 1
  }
  events=$(jq -jRs -L "$SF_ROOT" \
    -f "$SF_ROOT/tui/transcript-decode.jq" "$session_path" 2>/dev/null) || {
    SF_PRESENT_ERROR="cannot read session: $session_path"
    return 1
  }
  fields=( "${(@0)${events%$'\0'}}" )
  sf_chat_reset
  SF_PRESENT_FOOTER=$SF_PRESENT_IDENTITY
  for (( index = 1; index + 6 <= ${#fields}; index += 7 )); do
    if [[ $fields[index] == batch_ok ]]; then
      complete=1
    elif [[ $fields[index] == turn_usage ]]; then
      sf_chat_footer_usage "$fields[index + 1]"
    else
      sf_chat_event "${(@)fields[index,index + 6]}" || {
        SF_PRESENT_ERROR='cannot build presentation transcript'
        return 1
      }
    fi
  done
  (( complete )) || {
    SF_PRESENT_ERROR="cannot read session: $session_path"
    return 1
  }
}
