emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -ga SF_PRESENT_ROW_TEXT=() SF_PRESENT_ROW_CURSOR=()
typeset -ga SF_PRESENT_ROW_KIND=() SF_PRESENT_ROW_HIGHLIGHTS=()
typeset -ga SF_PRESENT_ROW_SETTLED=()
typeset -ga SF_PRESENT_ROW_NODE=()
typeset -ga SF_PRESENT_ROW_SOURCE_END=()
typeset -gi SF_PRESENT_PREFIX_VISIBLE=0
# The furthest source offset an open node has filled a whole visual row to. This
# is the only boundary at which a growing line may be highlighted.
typeset -gi SF_PRESENT_ROW_BOUNDARY_NODE=0 SF_PRESENT_ROW_BOUNDARY=0
typeset -g SF_PRESENT_PREVIEW_REASONING=full SF_PRESENT_PREVIEW_CONTEXT=full
typeset -g SF_PRESENT_PREVIEW_TOOL_CALL=full SF_PRESENT_PREVIEW_TOOL_RESULT=full
typeset -ga SF_PRESENT_ACTIVITY_FRAMES=( ⠃ ⠁ ⠁ ⠃ ⠆ ⡄ ⡀ ⡀ ⡄ ⠆ )
typeset -g SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[1]}

sf_chat_rows_config() {
  local config=${1:-\{\}} values
  local -a limits
  values=$(jq -r '[.tui.preview_lines_reasoning // "full",
    .tui.preview_lines_context // "full",
    .tui.preview_lines_tool_call // "full",
    .tui.preview_lines_tool_result // "full"][]' <<<"$config") || return 1
  limits=( "${(@f)values}" )
  (( ${#limits} == 4 )) || return 1
  SF_PRESENT_PREVIEW_REASONING=$limits[1]
  SF_PRESENT_PREVIEW_CONTEXT=$limits[2]
  SF_PRESENT_PREVIEW_TOOL_CALL=$limits[3]
  SF_PRESENT_PREVIEW_TOOL_RESULT=$limits[4]
}

sf_chat_token_count() {
  local text=$1 exact=${2-}
  if [[ -n $exact ]]; then
    REPLY=$exact
  else
    REPLY=$(( (${#text} + 3) / 4 ))
  fi
}

# The notes trailing a completed tool result, in transcript order.
sf_chat_result_notes() {
  integer node=$1
  local code=$SF_PRESENT_NODE_STATUS[node]
  local -a notes=()
  [[ -z $code || $code == hidden ]] || notes+=( "exit $code" )
  [[ -z $SF_PRESENT_NODE_BLOCKED[node] ]] || notes+=( 'sandbox blocked' )
  REPLY=${(j: · :)notes}
}

sf_chat_preview_tail() {
  integer node=$1 hidden=$2
  local type=$SF_PRESENT_NODE_TYPE[node] state=$SF_PRESENT_NODE_STATE[node]
  local role=$SF_PRESENT_NODE_ROLE[node]
  local body=$SF_PRESENT_NODE_BODY[node]
  local exact='' tokens notes
  body=${body#"${body%%[!$'\n']*}"}
  body=${body%"${body##*[!$'\n']}"}
  if [[ $type == tool_call ]]; then
    if (( hidden )); then
      REPLY='│ …'
    else
      REPLY=''
    fi
    return
  fi
  [[ $type != reasoning ]] || exact=$SF_PRESENT_NODE_META[node]
  sf_chat_token_count "$body" "$exact"
  tokens=$REPLY
  REPLY=''
  case $type in
    message)
      [[ $role != system || ! hidden ]] || REPLY="… ~$tokens tokens"
      ;;
    reasoning)
      if [[ $state == open ]]; then
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
      ;;
    tool_result)
      if [[ $state == open ]]; then
        [[ $SF_PRESENT_NODE_STATUS[node] == permission ]] || {
          if (( hidden )); then
            REPLY="  … ~$tokens tokens $SF_PRESENT_ACTIVITY"
          else
            REPLY="╰ $SF_PRESENT_ACTIVITY"
          fi
        }
      else
        sf_chat_result_notes $node
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
      fi
      ;;
    injection)
      (( ! hidden )) || REPLY="  … ~$tokens tokens"
      ;;
  esac
}

# Appends a row with semantic style spans, resolving "type.role" before falling
# back to "type". The caller appends the matching row cursor separately.
sf_chat_row_append() {
  local text=$1 kind=$2 syntax=${5-} style_kind=${7:-$2} style highlight=''
  integer settled=$3 node=$4 source_end=${6:--1}
  style=${SF_PRESENT_STYLE[$style_kind]:-$SF_PRESENT_STYLE[${style_kind%%.*}]}
  [[ -z $style || -z $text ]] || highlight="0 ${#text} $style"
  [[ -z $syntax ]] || highlight+="${highlight:+ }$syntax"
  SF_PRESENT_ROW_TEXT+=( "$text" )
  SF_PRESENT_ROW_KIND+=( "$kind" )
  SF_PRESENT_ROW_HIGHLIGHTS+=( "$highlight" )
  SF_PRESENT_ROW_SETTLED+=( $settled )
  SF_PRESENT_ROW_NODE+=( $node )
  SF_PRESENT_ROW_SOURCE_END+=( $source_end )
}

sf_chat_cell_width() {
  local character=$1
  integer column=$2 code
  if [[ $character == $'\t' ]]; then
    REPLY=$(( 8 - column % 8 ))
    return
  fi
  code=$(( #character ))
  if (( code == 0 || (code >= 768 && code <= 879) ||
      (code >= 6832 && code <= 6911) || (code >= 7616 && code <= 7679) ||
      (code >= 8400 && code <= 8447) || code == 8205 ||
      (code >= 65024 && code <= 65039) || (code >= 65056 && code <= 65071) )); then
    REPLY=0
  elif (( (code >= 4352 && code <= 4447) || (code >= 9001 && code <= 9002) ||
      (code >= 11904 && code <= 42191) || (code >= 44032 && code <= 55203) ||
      (code >= 63744 && code <= 64255) || (code >= 65040 && code <= 65049) ||
      (code >= 65072 && code <= 65135) || (code >= 65280 && code <= 65376) ||
      (code >= 65504 && code <= 65510) || (code >= 126976 && code <= 129791) ||
      (code >= 131072 && code <= 262141) )); then
    REPLY=2
  else
    REPLY=1
  fi
}

# Render a bounded suffix from an opaque width-independent node cursor.
sf_chat_rows() {
  integer columns=$1 budget=$2 node offset length consumed settled start
  integer column size take break_consumed break_length activity withhold withhold_all
  integer withhold_separator
  integer decorated previewed collapsed body_start=-1 body_end=0 preview_used=0 hidden=0
  integer content_start=-1 content_end=-1 source_base=0 source_end=0 frontier=-1
  integer separator_row transition tail_phase=0 complete_row
  integer display_start map_start map_end run_start break_run map span span_index=1
  integer span_start span_end row_start row_end highlight_start highlight_end
  integer diff_row diff_span part_column
  integer section_start section_end section_row_start section_row_end
  integer section_id_start section_id_end section_id_row_start section_id_row_end
  integer value_start=-1 value_stop=-1
  integer clamp_start=-1 clamp_stop=-1
  local cursor=${3:-1:0} text part state type heading body spans character run activity_text
  local leading
  local break_text display prefix preview=full head tail exact cursor_value row_highlight
  local style_kind divider_style title_style clamp_style title_value
  local -a cursor_parts row_map break_map source_spans projected characters

  (( columns > 0 && budget > 0 )) || return 1
  cursor_parts=( ${(s.:.)cursor} )
  (( ${#cursor_parts} == 2 || ${#cursor_parts} == 3 || ${#cursor_parts} == 4 )) || return 1
  [[ $cursor_parts[1] == <-> ]] || return 1
  node=$cursor_parts[1]
  (( node > 0 )) || return 1
  if (( ${#cursor_parts} == 4 )); then
    [[ $cursor_parts[2] == t && $cursor_parts[3] == <-> && $cursor_parts[4] == (0|1) ]] || return 1
    tail_phase=1
    offset=$cursor_parts[3]
    hidden=$cursor_parts[4]
  else
    [[ $cursor_parts[2] == <-> ]] || return 1
    offset=$cursor_parts[2]
    if (( ${#cursor_parts} == 3 )); then
      [[ $cursor_parts[3] == <-> ]] || return 1
      preview_used=$cursor_parts[3]
    fi
  fi
  SF_PRESENT_ROW_TEXT=()
  SF_PRESENT_ROW_CURSOR=()
  SF_PRESENT_ROW_KIND=()
  SF_PRESENT_ROW_HIGHLIGHTS=()
  SF_PRESENT_ROW_SETTLED=()
  SF_PRESENT_ROW_NODE=()
  SF_PRESENT_ROW_SOURCE_END=()
  SF_PRESENT_ROW_BOUNDARY_NODE=0
  SF_PRESENT_ROW_BOUNDARY=0

  while (( node <= ${#SF_PRESENT_NODE_TYPE} )); do
    type=$SF_PRESENT_NODE_TYPE[node]
    heading=$SF_PRESENT_NODE_HEADING[node]
    body=$SF_PRESENT_NODE_BODY[node]
    source_spans=( ${(s: :)${SF_PRESENT_HIGHLIGHT_CACHE[node]-}} )
    span_index=1
    state=$SF_PRESENT_NODE_STATE[node]
    frontier=${SF_PRESENT_NODE_FRONTIER[node]:--1}
    activity=0
    activity_text=$SF_PRESENT_ACTIVITY
    withhold=0
    withhold_all=0
    withhold_separator=0
    decorated=0
    previewed=0
    collapsed=0
    body_start=-1
    body_end=0
    content_start=-1
    content_end=-1
    section_id_start=-1
    section_id_end=-1
    source_base=0
    value_start=-1
    value_stop=-1
    clamp_start=-1
    clamp_stop=-1
    head=''
    preview=full

    if (( tail_phase )); then
      sf_chat_preview_tail $node $hidden
      text=$REPLY
      length=${#text}
      (( offset <= length )) || return 1
      text=${text[offset + 1,-1]}
    else
      case $type in
        activity)
          text=$SF_PRESENT_ACTIVITY
          withhold_all=1
          withhold_separator=1
          ;;
        section)
          text="─ $SF_PRESENT_NODE_ROLE[node] "
          section_start=2
          section_end=${#text}
          if [[ -n $heading ]] && (( ${#text} + ${#heading} + 3 <= columns )); then
            text+=${(l:$(( columns - ${#text} - ${#heading} - 3 ))::─:)""}
            text+=" $heading ─"
            section_id_start=$(( ${#text} - ${#heading} - 2 ))
            section_id_end=$(( section_id_start + ${#heading} ))
          else
            (( ${#text} < columns )) && text+=${(l:$(( columns - ${#text} ))::─:)""}
          fi
          ;;
        message)
          text=$body
          if [[ $SF_PRESENT_NODE_ROLE[node] == system ]]; then
            previewed=1
            preview=$SF_PRESENT_PREVIEW_CONTEXT
            if [[ $preview == 0 && -n $body ]]; then
              sf_chat_token_count "$body"
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
          ;;
        reasoning)
          decorated=1
          preview=$SF_PRESENT_PREVIEW_REASONING
          head='✎ Reasoning'
          ;;
        tool_call)
          decorated=1
          preview=$SF_PRESENT_PREVIEW_TOOL_CALL
          head="⛭ $heading"
          ;;
        tool_result)
          decorated=1
          preview=$SF_PRESENT_PREVIEW_TOOL_RESULT
          [[ $SF_PRESENT_NODE_META[node] != full ]] || preview=full
          ;;
        injection)
          decorated=1
          preview=$SF_PRESENT_PREVIEW_CONTEXT
          head="↪ $heading"
          ;;
        notice)
          decorated=1
          if [[ $SF_PRESENT_NODE_ROLE[node] == error ]]; then
            head="✕ $heading"
          else
            head="ℹ $heading"
          fi
          ;;
        *) return 1 ;;
      esac
      if [[ $type == (tool_call|injection|notice) ]]; then
        [[ -z $SF_PRESENT_NODE_META[node] ]] || head+=" · $SF_PRESENT_NODE_META[node]"
        value_start=2
        title_value=$heading
        value_stop=$(( value_start + ${#title_value} ))
      fi
      if (( decorated )); then
        previewed=1
        leading=${body%%[!$'\n']*}
        source_base=${#leading}
        body=${body#"$leading"}
        body=${body%"${body##*[!$'\n']}"}
        if [[ $preview == 0 && $type != notice ]]; then
          collapsed=1
          if [[ $type != (tool_call|tool_result) ]]; then
            exact=''
            [[ $type != reasoning ]] || exact=$SF_PRESENT_NODE_META[node]
            sf_chat_token_count "$body" "$exact"
          fi
          if [[ $type == reasoning ]]; then
            if [[ $state == open ]]; then
              text="✎ Thinking… $SF_PRESENT_ACTIVITY"
            else
              text="✎ Thought for ~$REPLY tokens."
            fi
          elif [[ $type == tool_call ]]; then
            text=$head
          elif [[ $type == tool_result ]]; then
            text='╰'
            [[ -z $body ]] || text+=' …'
            if [[ $state == open ]]; then
              text+=" $SF_PRESENT_ACTIVITY"
            else
              sf_chat_result_notes $node
              [[ -z $REPLY ]] || text+=" · $REPLY"
            fi
          else
            text=$head
            [[ -z $body ]] || text+=" · ~$REPLY tokens"
          fi
          case $type in
            reasoning) clamp_start=0 ;;
            tool_result) [[ -z $body ]] || clamp_start=2 ;;
            injection) [[ -z $body ]] || clamp_start=$(( ${#head} + 1 )) ;;
          esac
          if (( clamp_start >= 0 )); then
            clamp_stop=${#text}
          fi
          [[ $state != open ]] || withhold_all=1
        else
          if [[ $type == tool_result ]]; then
            text=$body
          else
            text=$head
            if [[ -n $body ]]; then
              text+=$'\n'$body
            fi
          fi
          [[ $type != tool_result || $SF_PRESENT_NODE_STATUS[node] != permission ]] || withhold_all=1
          if [[ $state == open && -z $body ]] && (( ! withhold_all )); then
            sf_chat_preview_tail $node 0
            if [[ -n $REPLY ]]; then
              activity=1
              activity_text=$REPLY
            fi
          fi
        fi
      fi
      if [[ $type == message && -z $text ]] && (( ! activity )); then
        (( node++ ))
        offset=0
        preview_used=0
        continue
      fi
      if (( ! collapsed && ${#body} )); then
        case $type in
          message|tool_result) content_start=0 ;;
          reasoning|tool_call|injection|notice) content_start=$(( ${#text} - ${#body} )) ;;
        esac
        if (( content_start >= 0 )); then
          content_end=$(( content_start + ${#body} ))
        fi
      fi
      if [[ $type != tool_result ]]; then
        if (( node != 1 || SF_PRESENT_PREFIX_VISIBLE )); then
          text=$'\n'$text
          if (( value_start >= 0 )); then
            (( value_start++, value_stop++ ))
          fi
          if (( clamp_start >= 0 )); then
            (( clamp_start++, clamp_stop++ ))
          fi
          if (( content_start >= 0 )); then
            (( content_start++, content_end++ ))
          fi
          if [[ $type == section ]]; then
            (( section_start++, section_end++ ))
            if (( section_id_start >= 0 )); then
              (( section_id_start++, section_id_end++ ))
            fi
          fi
        fi
      fi
      if (( previewed && ! collapsed && ${#body} )); then
        body_start=$(( ${#text} - ${#body} ))
        body_end=${#text}
      fi
      length=${#text}
      # Closing may trim trailing newlines the display cursor already consumed.
      if (( offset > length )) &&
          [[ $state == closed && $type == (message|reasoning) ]]; then
        offset=$length
      fi
      (( offset <= length )) || return 1
      # A settled decorated heading already owns its terminal row. When its
      # body arrives later, resume after the newly inserted join newline.
      if [[ $type != tool_result ]] &&
          (( decorated && ! collapsed && body_start > 0 && offset + 1 == body_start )); then
        (( offset++ ))
      fi
      if (( offset == length )); then
        if (( previewed && ! collapsed )); then
          if [[ $state == open ]] && (( activity )); then
            text=''
          else
            sf_chat_preview_tail $node 0
          fi
          if (( ! activity )) && [[ -n $REPLY ]]; then
            tail_phase=1
            hidden=0
            offset=0
            text=$REPLY
            length=${#text}
          elif [[ $state == closed ]]; then
            (( node++ ))
            offset=0
            preview_used=0
            continue
          elif (( activity )); then
            text=''
          else
            break
          fi
        elif [[ $state == closed ]]; then
          (( node++ ))
          offset=0
          preview_used=0
          continue
        elif (( ! activity )); then
          break
        else
          text=''
        fi
      else
        text=${text[offset + 1,-1]}
      fi
    fi

    while [[ -n $text ]]; do
      if (( ${#SF_PRESENT_ROW_TEXT} >= budget )); then
        return 0
      fi
      start=$offset
      part=''
      column=0
      row_map=()
      break_map=()
      if [[ $type == tool_result ]] &&
          (( (tail_phase || collapsed) && offset > 0 && columns > 2 )); then
        part='  '
        column=2
      elif (( decorated && ! collapsed && ! tail_phase && body_start >= 0 &&
          start >= body_start && columns > 2 )); then
        if [[ $type == tool_call ]]; then
          part='│ '
        elif [[ $type == tool_result && $start == $body_start ]]; then
          part='╰ '
        else
          part='  '
        fi
        column=2
      fi
      consumed=0
      settled=0
      source_end=-1
      break_consumed=0
      break_length=0
      while [[ -n $text ]]; do
        if (( column >= columns )); then
          character=$text[1]
          if [[ $character == $'\n' ]]; then
            text=${text[2,-1]}
            consumed=$(( consumed + 1 ))
            offset=$(( offset + 1 ))
            settled=1
            break
          fi
          if [[ $character == ' ' ]]; then
            text=${text[2,-1]}
            consumed=$(( consumed + 1 ))
            offset=$(( offset + 1 ))
            settled=1
            break
          fi
          sf_chat_cell_width "$character" $column
          size=$REPLY
          if (( size > 0 )); then
            if (( break_consumed )); then
              text=$break_text
              offset=$(( start + break_consumed ))
              consumed=$break_consumed
              part=${part[1,break_length]}
              row_map=( "${(@)break_map}" )
            fi
            settled=1
            break
          fi
          display_start=${#part}
          if (( content_start >= 0 && offset >= content_start && offset < content_end )); then
            map_start=$(( source_base + offset - content_start ))
            row_map+=( $map_start $(( map_start + 1 )) $display_start
              $(( display_start + 1 )) )
          fi
          part+=$character
          text=${text[2,-1]}
          consumed=$(( consumed + 1 ))
          offset=$(( offset + 1 ))
          continue
        fi
        take=$(( columns - column ))
        run=${text[1,take]}
        run=${run%%[^ -~]*}
        if [[ -n $run ]]; then
          take=${#run}
          run_start=$offset
          display_start=${#part}
          if [[ $run == *' '* ]]; then
            prefix=${run% *}
            if (( ${#part} + ${#prefix} )); then
              break_consumed=$(( consumed + ${#prefix} + 1 ))
              break_length=$(( ${#part} + ${#prefix} ))
              break_text=${text[${#prefix} + 2,-1]}
              break_map=( "${(@)row_map}" )
              break_run=${#prefix}
              map_start=$(( run_start > content_start ? run_start : content_start ))
              map_end=$(( run_start + break_run < content_end ?
                run_start + break_run : content_end ))
              if (( content_start >= 0 && map_end > map_start )); then
                break_map+=(
                  $(( source_base + map_start - content_start ))
                  $(( source_base + map_end - content_start ))
                  $(( display_start + map_start - run_start ))
                  $(( display_start + map_end - run_start )) )
              fi
            fi
          fi
          map_start=$(( run_start > content_start ? run_start : content_start ))
          map_end=$(( run_start + take < content_end ? run_start + take : content_end ))
          if (( content_start >= 0 && map_end > map_start )); then
            row_map+=(
              $(( source_base + map_start - content_start ))
              $(( source_base + map_end - content_start ))
              $(( display_start + map_start - run_start ))
              $(( display_start + map_end - run_start )) )
          fi
          part+=${run[1,take]}
          text=${text[take + 1,-1]}
          consumed=$(( consumed + take ))
          offset=$(( offset + take ))
          column=$(( column + take ))
          continue
        fi
        character=$text[1]
        if [[ $character == $'\n' ]]; then
          text=${text[2,-1]}
          consumed=$(( consumed + 1 ))
          offset=$(( offset + 1 ))
          settled=1
          break
        fi
        sf_chat_cell_width "$character" $column
        size=$REPLY
        if [[ $character == $'\t' && $column == 0 ]] && (( size > columns )); then
          size=$columns
        fi
        if (( column > 0 && column + size > columns )); then
          if (( break_consumed )); then
            text=$break_text
            offset=$(( start + break_consumed ))
            consumed=$break_consumed
            part=${part[1,break_length]}
            row_map=( "${(@)break_map}" )
          fi
          settled=1
          break
        fi
        if [[ $character == $'\t' ]]; then
          display=${(l:size:)""}
        else
          display=$character
        fi
        display_start=${#part}
        if (( content_start >= 0 && offset >= content_start && offset < content_end )); then
          map_start=$(( source_base + offset - content_start ))
          row_map+=( $map_start $(( map_start + 1 )) $display_start
            $(( display_start + ${#display} )) )
        fi
        part+=$display
        text=${text[2,-1]}
        consumed=$(( consumed + 1 ))
        offset=$(( offset + 1 ))
        column=$(( column + size ))
      done
      if [[ -z $text && $state == closed ]]; then
        settled=1
      fi
      # Settling is about the frontier; filling is about wrapping. Capture the
      # latter first, because it is what lets the frontier advance at all.
      complete_row=$settled
      if (( ! tail_phase && frontier >= 0 && content_start >= 0 && offset > content_start )); then
        source_end=$(( offset < content_end ? offset - content_start : content_end - content_start ))
        source_end=$(( source_base + source_end ))
        (( source_end <= frontier )) || settled=0
        if (( complete_row )) && [[ $state == open ]]; then
          SF_PRESENT_ROW_BOUNDARY_NODE=$node
          SF_PRESENT_ROW_BOUNDARY=$source_end
        fi
      fi
      if (( decorated && ! collapsed && ! tail_phase && body_start < 0 )) &&
          [[ $state == open && $SF_PRESENT_NODE_STATUS[node] != permission ]]; then
        settled=1
      fi
      separator_row=0
      if (( node > 1 && start == 0 && ! tail_phase )) && [[ -z $part && $consumed == 1 ]]; then
        separator_row=1
      fi
      (( ! withhold_all || (separator_row && ! withhold_separator) )) || settled=0
      if (( withhold && ! settled )) && [[ -z $text ]]; then
        break
      fi
      transition=0
      if (( previewed && ! collapsed && ! tail_phase && body_start >= 0 && start >= body_start )); then
        (( ++preview_used ))
        if [[ $preview != full ]] && (( preview_used >= preview && offset < body_end )); then
          hidden=1
          transition=1
        fi
      fi
      if (( separator_row )); then
        spans=separator
      else
        spans=$type${SF_PRESENT_NODE_ROLE[node]:+.$SF_PRESENT_NODE_ROLE[node]}
      fi
      projected=()
      if (( ${#row_map} )); then
        row_start=${row_map[1]}
        row_end=${row_map[-3]}
        while (( span_index <= ${#source_spans} &&
            source_spans[span_index + 1] <= row_start )); do
          (( span_index += 3 ))
        done
        span=$span_index
        while (( span <= ${#source_spans} && source_spans[span] < row_end )); do
          span_start=${source_spans[span]}
          span_end=${source_spans[span + 1]}
          for (( map = 1; map <= ${#row_map}; map += 4 )); do
            map_start=${row_map[map]}
            map_end=${row_map[map + 1]}
            (( span_start < map_end && span_end > map_start )) || continue
            display_start=${row_map[map + 2]}
            highlight_end=${row_map[map + 3]}
            if (( map_end - map_start == highlight_end - display_start )); then
              highlight_start=$(( display_start +
                (span_start > map_start ? span_start - map_start : 0) ))
              highlight_end=$(( highlight_end -
                (span_end < map_end ? map_end - span_end : 0) ))
            else
              highlight_start=$display_start
            fi
            (( highlight_end > highlight_start )) || continue
            if (( ${#projected} >= 3 )) && [[ ${projected[-2]} == $highlight_start &&
                ${projected[-1]} == ${source_spans[span + 2]} ]]; then
              projected[-2]=$highlight_end
            else
              projected+=( $highlight_start $highlight_end "${source_spans[span + 2]}" )
            fi
          done
          (( span += 3 ))
        done
      fi
      style_kind=$spans
      if [[ $type == section ]]; then
        style_kind=separator
        divider_style=$SF_PRESENT_STYLE[divider]
        title_style=${SF_PRESENT_STYLE[$spans]:-$SF_PRESENT_STYLE[section]}
        section_row_start=$(( section_start > start ? section_start - start : 0 ))
        section_row_end=$(( section_end - start < ${#part} ? section_end - start : ${#part} ))
        (( section_row_end > 0 )) || section_row_end=0
        (( section_row_start < ${#part} )) || section_row_start=${#part}
        [[ -z $divider_style ]] || (( section_row_start == 0 )) ||
          projected+=( 0 $section_row_start "$divider_style" )
        [[ -z $title_style ]] || (( section_row_end <= section_row_start )) ||
          projected+=( $section_row_start $section_row_end "$title_style" )
        [[ -z $divider_style ]] || (( section_row_end == ${#part} )) ||
          projected+=( $section_row_end ${#part} "$divider_style" )
        if (( section_id_start >= 0 )); then
          section_id_row_start=$(( section_id_start > start ? section_id_start - start : 0 ))
          section_id_row_end=$(( section_id_end - start < ${#part} ? section_id_end - start : ${#part} ))
          [[ -z $SF_PRESENT_STYLE[muted] ]] || (( section_id_row_end <= section_id_row_start )) ||
            projected+=( $section_id_row_start $section_id_row_end "$SF_PRESENT_STYLE[muted]" )
        fi
      fi
      if (( ! tail_phase && value_start < offset && value_stop > start )); then
        highlight_start=$(( value_start > start ? value_start - start : 0 ))
        highlight_end=$(( value_stop < start + ${#part} ? value_stop - start : ${#part} ))
        title_style=${SF_PRESENT_STYLE[$style_kind]:-$SF_PRESENT_STYLE[${style_kind%%.*}]}
        [[ -z $title_style ]] || (( highlight_end <= highlight_start )) ||
          projected+=( $highlight_start $highlight_end "$title_style,bold" )
      fi
      clamp_style=$SF_PRESENT_STYLE[clamp]
      if (( tail_phase )) && [[ $hidden == 1 || $type == reasoning ]]; then
        [[ -z $clamp_style || -z $part ]] || projected+=( 0 ${#part} "$clamp_style" )
      elif (( clamp_start < offset && clamp_stop > start )); then
        highlight_start=$(( clamp_start > start ? clamp_start - start : 0 ))
        highlight_end=$(( clamp_stop < start + ${#part} ? clamp_stop - start : ${#part} ))
        [[ -z $clamp_style ]] || (( highlight_end <= highlight_start )) ||
          projected+=( $highlight_start $highlight_end "$clamp_style" )
      fi
      if [[ $type == (tool_call|tool_result) && $part == (│|╰)* ]]; then
        [[ -z $SF_PRESENT_STYLE[divider] ]] || projected+=( 0 1 "$SF_PRESENT_STYLE[divider]" )
      fi
      diff_row=0
      if [[ $SF_PRESENT_NODE_FORMAT[node] == file_diff ]]; then
        for (( span = 1; span <= ${#projected}; span += 3 )); do
          if [[ (-n $SF_PRESENT_STYLE[syntax.added] &&
                ${projected[span + 2]} == $SF_PRESENT_STYLE[syntax.added]) ||
              (-n $SF_PRESENT_STYLE[syntax.removed] &&
                ${projected[span + 2]} == $SF_PRESENT_STYLE[syntax.removed]) ]]; then
            diff_row=1
            diff_span=$span
            break
          fi
        done
      fi
      if (( diff_row )); then
        part_column=0
        characters=( ${(s::)part} )
        for character in $characters; do
          sf_chat_cell_width "$character" $part_column
          part_column=$(( part_column + REPLY ))
        done
        (( part_column >= columns )) || part+="${(l:$(( columns - part_column )):: :)}"
        projected=( 0 ${#part} "${projected[diff_span + 2]}" )
      fi
      row_highlight="${(j: :)projected}"
      sf_chat_row_append "$part" "$spans" $settled $node "$row_highlight" $source_end \
        "$style_kind"

      if (( previewed && ! collapsed && ! tail_phase && ! transition )) &&
          [[ -z $text ]] && (( ! activity )); then
        transition=1
        hidden=0
      fi
      if (( transition )); then
        sf_chat_preview_tail $node $hidden
        tail=$REPLY
        if [[ -n $tail ]]; then
          SF_PRESENT_ROW_CURSOR+=( "${node}:t:0:$hidden" )
          tail_phase=1
          offset=0
          text=$tail
          length=${#text}
          continue
        fi
        text=''
      fi
      if (( tail_phase )); then
        if (( offset == length )) && [[ $state == closed ]]; then
          cursor_value="$(( node + 1 )):0"
        else
          cursor_value="${node}:t:$offset:$hidden"
        fi
      elif (( offset == length )) && [[ $state == closed ]]; then
        cursor_value="$(( node + 1 )):0"
      elif (( previewed && ! collapsed )) && [[ $preview != full ]]; then
        cursor_value="$node:$offset:$preview_used"
      else
        cursor_value="$node:$offset"
      fi
      SF_PRESENT_ROW_CURSOR+=( "$cursor_value" )
    done
    if (( activity )); then
      if (( ${#SF_PRESENT_ROW_TEXT} >= budget )); then
        return 0
      fi
      spans=$type${SF_PRESENT_NODE_ROLE[node]:+.$SF_PRESENT_NODE_ROLE[node]}
      row_highlight=''
      if [[ $type == tool_result && $activity_text == ╰* && -n $SF_PRESENT_STYLE[divider] ]]; then
        row_highlight="0 1 $SF_PRESENT_STYLE[divider]"
      fi
      sf_chat_row_append "$activity_text" "$spans" 0 $node "$row_highlight"
      SF_PRESENT_ROW_CURSOR+=( "$node:$offset" )
    fi
    [[ $state == closed ]] || break
    (( node++ ))
    offset=0
    preview_used=0
    hidden=0
    tail_phase=0
  done
}
