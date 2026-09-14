emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -g SF_PRESENT_PREVIEW_REASONING=full SF_PRESENT_PREVIEW_CONTEXT=full
typeset -ga SF_PRESENT_ACTIVITY_FRAMES=( ⠃ ⠁ ⠁ ⠁ ⠃ ⠆ ⡄ ⡀ ⡀ ⡀ ⡄ ⠆ )
typeset -g SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[1]}

sf_tui_rows_config() {
  local config=${1:-\{\}} values
  local -a limits
  values=$(jq -r '[.tui.preview_lines_reasoning // "full",
    .tui.preview_lines_context // "full"][]' <<<"$config") || return 1
  limits=( "${(@f)values}" )
  (( ${#limits} == 2 )) || return 1
  SF_PRESENT_PREVIEW_REASONING=$limits[1]
  SF_PRESENT_PREVIEW_CONTEXT=$limits[2]
}

sf_tui_token_count() {
  integer characters=${1:-0}
  if [[ -n ${2-} ]]; then
    REPLY=$2
  else
    REPLY=$(( (characters + 3) / 4 ))
  fi
}

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

sf_tui_format_execution() {
  integer index=$1 columns=$2 identity_start=$6 live=$7 spinner=$8
  integer row limit offset chrome total hidden=0
  local glyph=$3 kind=$4 script=$5 body=$9 preview=${10:-full} text
  local base_style=${SF_PRESENT_STYLE[$kind]-} rail_style=${SF_PRESENT_STYLE[divider]-}
  local -a projected=() spans=()

  sf_tui_format_rule $index $columns
  chrome=${#SF_FORMAT_ROWS}
  SF_PRESENT_HIGHLIGHT_SPANS=()
  offset=$(( identity_start - SF_FORMAT_TRIM_LEADING ))
  if (( offset >= 0 && offset + ${#script} <= ${#body} )); then
    SF_PRESENT_HIGHLIGHT_SPANS+=( $offset ${#script} bold )
  fi
  sf_tui_wrap $columns "$body" '│ ' "${(@)SF_PRESENT_HIGHLIGHT_SPANS}" || return 1
  total=${#SF_WRAP_ROWS}
  limit=$total
  # The identity row always shows; the preview budget covers the output below it.
  if (( ! live )) && [[ $preview != full ]] && (( total > preview + 1 )); then
    limit=$(( preview + 1 ))
    hidden=1
  fi
  for (( row = 1; row <= limit; row++ )); do
    text=$SF_WRAP_ROWS[row]
    if (( row == 1 )); then
      text="$glyph${text[2,-1]}"
    elif (( ! live && ! hidden && row == limit )); then
      text="╰${text[2,-1]}"
    fi
    projected=( ${=SF_WRAP_SPANS[row]} )
    spans=()
    [[ -z $base_style || -z $text ]] || spans+=( 0 ${#text} "$base_style" )
    [[ -z $rail_style || $text != (│|╰)* ]] || spans+=( 0 1 "$rail_style" )
    spans+=( "${(@)projected}" )
    SF_FORMAT_ROWS+=( "$text" )
    SF_FORMAT_SPANS+=( "${(j: :)spans}" )
    SF_FORMAT_CONSUMED+=( $SF_WRAP_CONSUMED[row] )
  done
  if (( spinner )); then
    sf_tui_format_styled $columns "╰ $SF_PRESENT_ACTIVITY" "$kind" '' activity || return 1
  elif (( hidden )); then
    sf_tui_token_count ${#body}
    sf_tui_format_styled $columns "╰ … ~$REPLY tokens" "$kind" clamp || return 1
  elif (( ! live && limit <= 1 )); then
    sf_tui_format_styled $columns '╰' "$kind" || return 1
  fi
  SF_FORMAT_LEADING=$(( ${#SF_FORMAT_ROWS} > chrome ? chrome + 1 : chrome ))
  SF_FORMAT_BODY_ROWS=$limit
  (( live )) || SF_FORMAT_SAFE=${#SF_FORMAT_ROWS}
}

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
