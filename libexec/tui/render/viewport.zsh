emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -g SF_PRESENT_VIEWPORT_TEXT='' SF_PRESENT_FLUSH_TEXT=''
typeset -g SF_PRESENT_FLUSH_CURSOR=''
typeset -ga SF_PRESENT_VIEWPORT_HIGHLIGHTS=() SF_PRESENT_FLUSH_HIGHLIGHTS=()
typeset -gi SF_PRESENT_FLUSH_ROWS=0
typeset -gi SF_PRESENT_FLUSH_SOURCE_NODE=0 SF_PRESENT_FLUSH_SOURCE_OFFSET=0

sf_tui_collect_highlights() {
  integer count=$1 row offset=0 index start end
  local -a fields
  reply=()
  for (( row = 1; row <= count; row++ )); do
    fields=( ${(s: :)SF_PRESENT_ROW_HIGHLIGHTS[row]} )
    (( ${#fields} % 3 == 0 )) || return 1
    for (( index = 1; index <= ${#fields}; index += 3 )); do
      [[ ${fields[index]} == <-> && ${fields[index + 1]} == <-> ]] || return 1
      start=${fields[index]}
      end=${fields[index + 1]}
      (( end > start && end <= ${#SF_PRESENT_ROW_TEXT[row]} )) || return 1
      [[ -n ${fields[index + 2]} && ${fields[index + 2]} != *[[:space:]]* ]] || return 1
      reply+=( $(( offset + start )) $(( offset + end )) "${fields[index + 2]}" )
    done
    offset=$(( offset + ${#SF_PRESENT_ROW_TEXT[row]} + 1 ))
  done
}

sf_tui_viewport() {
  integer columns=$1 budget=$2 index open_node=0 open_rows=0
  local cursor=${3:-1:0}
  local -a flushed

  sf_tui_rows $columns $budget "$cursor" || return 1
  SF_PRESENT_VIEWPORT_TEXT=${(F)SF_PRESENT_ROW_TEXT}
  SF_PRESENT_FLUSH_TEXT=''
  SF_PRESENT_FLUSH_CURSOR=''
  SF_PRESENT_VIEWPORT_HIGHLIGHTS=()
  SF_PRESENT_FLUSH_HIGHLIGHTS=()
  SF_PRESENT_FLUSH_ROWS=0
  SF_PRESENT_FLUSH_SOURCE_NODE=0
  SF_PRESENT_FLUSH_SOURCE_OFFSET=0
  (( ${#SF_PRESENT_ROW_TEXT} )) || return 0
  sf_tui_collect_highlights ${#SF_PRESENT_ROW_TEXT} || return 1
  SF_PRESENT_VIEWPORT_HIGHLIGHTS=( "${(@)reply}" )

  if (( ${#SF_PRESENT_NODE_TYPE} )) && [[ $SF_PRESENT_NODE_STATE[-1] == open ]]; then
    open_node=${#SF_PRESENT_NODE_TYPE}
  fi
  for (( index = 1; index <= ${#SF_PRESENT_ROW_TEXT}; index++ )); do
    (( SF_PRESENT_ROW_SETTLED[index] )) || break
    if (( SF_PRESENT_ROW_NODE[index] == open_node )) &&
        [[ $SF_PRESENT_ROW_KIND[index] != separator ]]; then
      (( ++open_rows > 1 )) && break
    fi
    SF_PRESENT_FLUSH_ROWS=$index
  done
  if (( SF_PRESENT_FLUSH_ROWS )) &&
      [[ $SF_PRESENT_ROW_KIND[SF_PRESENT_FLUSH_ROWS] == separator ]] &&
      (( ${#SF_PRESENT_ROW_TEXT} > 1 )); then
    (( SF_PRESENT_FLUSH_ROWS-- ))
  fi
  (( SF_PRESENT_FLUSH_ROWS )) || return 0
  flushed=( "${(@)SF_PRESENT_ROW_TEXT[1,SF_PRESENT_FLUSH_ROWS]}" )
  SF_PRESENT_FLUSH_TEXT=${(F)flushed}
  SF_PRESENT_FLUSH_CURSOR=$SF_PRESENT_ROW_CURSOR[SF_PRESENT_FLUSH_ROWS]
  for (( index = 1; index <= SF_PRESENT_FLUSH_ROWS; index++ )); do
    if (( SF_PRESENT_ROW_SOURCE_END[index] >= 0 )); then
      SF_PRESENT_FLUSH_SOURCE_NODE=$SF_PRESENT_ROW_NODE[index]
      SF_PRESENT_FLUSH_SOURCE_OFFSET=$SF_PRESENT_ROW_SOURCE_END[index]
    fi
  done
  sf_tui_collect_highlights $SF_PRESENT_FLUSH_ROWS || return 1
  SF_PRESENT_FLUSH_HIGHLIGHTS=( "${(@)reply}" )
}
