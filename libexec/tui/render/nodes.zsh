emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

# The presentation transcript. This file owns the shared add, append, close, and
# drop operations; each formatter owns the entries it creates.
typeset -ga SF_PRESENT_NODE_TYPE=() SF_PRESENT_NODE_ROLE=()
typeset -ga SF_PRESENT_NODE_HEADING=() SF_PRESENT_NODE_BODY=()
typeset -ga SF_PRESENT_NODE_META=() SF_PRESENT_NODE_STATE=()
typeset -ga SF_PRESENT_NODE_STATUS=() SF_PRESENT_NODE_FORMAT=()
# Marks a tool result accompanied by a detected sandbox denial.
typeset -ga SF_PRESENT_NODE_SANDBOX_DENIAL=()
# A formatter enables the node frontier before body rows can flush. A negative
# frontier preserves ordinary row settlement.
typeset -ga SF_PRESENT_NODE_FRONTIER=()
typeset -g SF_PRESENT_ERROR='' SF_PRESENT_LAST_ROLE=''
typeset -gi SF_PRESENT_SECTION_ID=0
typeset -g SF_PRESENT_ASSISTANT_INDEX=''
# The frozen session runtime, established by transcript replay and refreshed by
# live session updates.
typeset -g SF_PRESENT_RUNTIME='null'
typeset -g SF_PRESENT_IDENTITY='' SF_PRESENT_FOOTER=''

sf_tui_safe() {
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

sf_tui_reset() {
  sf_tui_drop ${#SF_PRESENT_NODE_TYPE}
  SF_PRESENT_TOOL_CALL=''
  SF_PRESENT_ASSISTANT_INDEX=''
  SF_PRESENT_LAST_ROLE=''
  SF_PRESENT_SECTION_ID=0
}

sf_tui_add() {
  local type=$1 role=${2-} heading=${3-} body=${4-} state=${5:-closed}
  integer last=${#SF_PRESENT_NODE_TYPE} index
  index=$(( last + 1 ))

  if (( last )) && [[ $SF_PRESENT_NODE_STATE[last] == open ]]; then
    return 1
  fi
  sf_tui_safe "$heading"; heading=$REPLY
  sf_tui_safe "$body"; body=$REPLY
  SF_PRESENT_NODE_TYPE[index]=$type
  SF_PRESENT_NODE_ROLE[index]=$role
  SF_PRESENT_NODE_HEADING[index]=$heading
  SF_PRESENT_NODE_BODY[index]=$body
  SF_PRESENT_NODE_STATE[index]=$state
  SF_PRESENT_NODE_FRONTIER[index]=-1
  REPLY=$index
}

sf_tui_set_frontier() {
  integer index=$1 offset=$2 current
  (( index > 0 && index <= ${#SF_PRESENT_NODE_TYPE} )) || return 1
  (( offset >= 0 && offset <= ${#SF_PRESENT_NODE_BODY[index]} )) || return 1
  current=$SF_PRESENT_NODE_FRONTIER[index]
  (( current < 0 || offset >= current )) || return 1
  SF_PRESENT_NODE_FRONTIER[index]=$offset
}

sf_tui_section() {
  local role=$1 id=''
  [[ $SF_PRESENT_LAST_ROLE != $role ]] || return 0
  if [[ $role == (user|agent) ]]; then
    (( ++SF_PRESENT_SECTION_ID ))
    id=$SF_PRESENT_SECTION_ID
  fi
  sf_tui_add section "$role" "$id" || {
    [[ -z $id ]] || (( --SF_PRESENT_SECTION_ID ))
    return 1
  }
  SF_PRESENT_LAST_ROLE=$role
}

sf_tui_drop() {
  integer count=$1 total=${#SF_PRESENT_NODE_TYPE}
  (( count >= 0 && count <= total )) || return 1
  (( count )) || return 0
  sf_tui_highlight_drop $count
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

sf_tui_close() {
  integer index=$1 end section removed_section=0
  local body
  [[ $index == ${#SF_PRESENT_NODE_TYPE} && $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
  body=$SF_PRESENT_NODE_BODY[index]
  if [[ $SF_PRESENT_NODE_TYPE[index] == (message|reasoning) && $body != *[!$'\n']* ]]; then
    body=''
  fi
  if [[ $SF_PRESENT_NODE_TYPE[index] == (activity|hook_activity|message|reasoning) &&
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

sf_tui_append() {
  integer index=$1
  local text=${2-}
  [[ $index == ${#SF_PRESENT_NODE_TYPE} && $SF_PRESENT_NODE_STATE[index] == open ]] || return 1
  [[ -n $text ]] || return 0
  sf_tui_safe "$text"
  SF_PRESENT_NODE_BODY[index]+=$REPLY
}

sf_tui_footer_usage() {
  SF_PRESENT_FOOTER="${SF_PRESENT_IDENTITY} · $1"
}

# The runtime is a validated session header, so its identity always resolves.
sf_tui_session_update() {
  SF_PRESENT_RUNTIME=$1
  SF_PRESENT_IDENTITY=$(jq -r '.backend.name + "/" + .profile.request.model' <<<"$1")
  SF_PRESENT_FOOTER=$SF_PRESENT_IDENTITY
}

(( $+functions[sf_tui_user_message] )) ||
  source "$SF_ROOT/libexec/tui/render/messages.zsh"
(( $+functions[sf_tui_hook_activity] )) ||
  source "$SF_ROOT/libexec/tui/render/hooks.zsh"
(( $+functions[sf_tui_tool_call] )) ||
  source "$SF_ROOT/libexec/tui/render/tools.zsh"

sf_tui_event() {
  local type=$1 first=${2-} second=${3-} third=${4-} fourth=${5-} fifth=${6-} sixth=${7-}
  integer index=${#SF_PRESENT_NODE_TYPE}

  case $type in
    system|user)
      if [[ $type == system ]]; then
        sf_tui_system_message "$first"
      else
        sf_tui_user_message "$first"
      fi
      ;;
    assistant_start)
      sf_tui_assistant_start
      ;;
    assistant_message_delta)
      sf_tui_assistant_text "$first" "$second"
      ;;
    assistant_reasoning_delta)
      sf_tui_reasoning "$first" "$second" "$third"
      ;;
    reasoning_tokens)
      if [[ -n $first && $index -gt 0 && $SF_PRESENT_NODE_TYPE[index] == reasoning &&
          $SF_PRESENT_NODE_STATE[index] == open ]]; then
        SF_PRESENT_NODE_META[index]=$first
      fi
      ;;
    assistant_reasoning_opaque)
      sf_tui_assistant_block "$first"
      ;;
    assistant_tool_call_delta)
      sf_tui_assistant_block "$first"
      ;;
    assistant_end)
      sf_tui_assistant_end
      ;;
    tool_call)
      sf_tui_tool_call "$first" "$second" "$third" "$fourth" "$fifth"
      ;;
    tool_result)
      sf_tui_tool_result "$first" "$second" "$third" "$fourth" "$fifth" "$sixth"
      ;;
    tool_permission)
      sf_tui_tool_permission "$first"
      ;;
    tool_permission_clear)
      sf_tui_tool_permission_clear
      ;;
    hook_activity)
      sf_tui_hook_activity "$first" "$second" "$third"
      ;;
    hook_result)
      sf_tui_hook_result "$first" "$second" "$third" "$fourth"
      ;;
    error)
      sf_tui_error "$first" "$second" || return 1
      [[ $third != end ]] || SF_PRESENT_LAST_ROLE=''
      ;;
    *) return 1 ;;
  esac
}

sf_tui_reload() {
  local session_path=$1 events
  local -a fields
  integer complete=0 index

  SF_PRESENT_ERROR=''
  [[ -f $session_path && ! -L $session_path ]] || {
    SF_PRESENT_ERROR="invalid session path: $session_path"
    return 1
  }
  events=$(sf_jq -jRs -f "$SF_ROOT/libexec/tui/transcript-decode.jq" \
    <"$session_path" 2>/dev/null) || {
    SF_PRESENT_ERROR="cannot read session: $session_path"
    return 1
  }
  fields=( "${(@0)${events%$'\0'}}" )
  sf_tui_reset
  for (( index = 1; index + 6 <= ${#fields}; index += 7 )); do
    if [[ $fields[index] == batch_ok ]]; then
      complete=1
    elif [[ $fields[index] == session_update ]]; then
      sf_tui_session_update "$fields[index + 1]"
    elif [[ $fields[index] == turn_usage ]]; then
      sf_tui_footer_usage "$fields[index + 1]"
    else
      sf_tui_event "${(@)fields[index,index + 6]}" || {
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
