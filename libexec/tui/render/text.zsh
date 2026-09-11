emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Shared text utilities and presentation configuration, independent of what is
# being rendered.

typeset -g SF_PRESENT_PREVIEW_REASONING=full SF_PRESENT_PREVIEW_CONTEXT=full
typeset -g SF_PRESENT_PREVIEW_TOOL_CALL=full SF_PRESENT_PREVIEW_TOOL_RESULT=full
typeset -ga SF_PRESENT_ACTIVITY_FRAMES=( ⠃ ⠁ ⠁ ⠃ ⠆ ⡄ ⡀ ⡀ ⡄ ⠆ )
typeset -g SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[1]}

sf_tui_rows_config() {
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

# Shared display estimate: providers do not report token counts for every
# content block, so presentation uses about four characters per token.
sf_tui_token_count() {
  local text=$1 exact=${2-}
  if [[ -n $exact ]]; then
    REPLY=$exact
  else
    REPLY=$(( (${#text} + 3) / 4 ))
  fi
}

# Replaces control characters with U+FFFD, keeping the two whitespace controls
# that presentation lays out itself.
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

# Terminal cells occupied by one character at $2 columns into the row. Tabs
# advance to the next eight-column stop, so width depends on that position.
sf_tui_cell_width() {
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
