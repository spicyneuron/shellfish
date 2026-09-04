emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -ga SF_RESUME_ALL_PATHS=() SF_RESUME_PATHS=()
typeset -ga SF_RESUME_TIMES=() SF_RESUME_PAIRS=() SF_RESUME_PREVIEWS=()
typeset -g SF_RESUME_ERROR=''
typeset -gi SF_RESUME_LIMIT=10 SF_RESUME_CANCELLED=0 SF_RESUME_SELECTED=1 SF_RESUME_PAGE=0

sf_resume_fail() {
  SF_RESUME_ERROR=$1
  return 1
}

sf_resume_load() {
  local file field header current decoded=0
  local -a lines headers readable raw_lasts
  local -A last_by_file
  SF_RESUME_ERROR=''
  SF_RESUME_PATHS=( "$@" )
  SF_RESUME_TIMES=()
  SF_RESUME_PAIRS=()
  SF_RESUME_PREVIEWS=()
  for file in "$@"; do
    header=''
    if [[ -f $file && -r $file && ! -L $file ]]; then
      readable+=( "$file" )
      IFS= read -r header <"$file" 2>/dev/null
    fi
    headers+=( "${header:-null}" )
  done
  # The extra file forces headed output, whose boundaries preserve torn records
  # without starting a tail process per session.
  raw_lasts=( "${(@f)$(tail -n 1 -- "${readable[@]}" /dev/null 2>/dev/null)}" )
  integer expect_record=0
  for field in "${raw_lasts[@]}"; do
    if [[ $field == '==> '*' <==' ]]; then
      [[ $field == '==> /dev/null <==' ]] && break
      current=${${field#'==> '}%' <=='}
      last_by_file[$current]=null
      expect_record=1
    elif (( expect_record )); then
      last_by_file[$current]=$field
      expect_record=0
    fi
  done
  for (( file = 1; file <= ${#headers}; file++ )); do
    lines+=( "$headers[file]" "${last_by_file[${SF_RESUME_PATHS[file]}]:-null}" )
  done
  while IFS= read -r -d '' field; do
    [[ $field != ok ]] || { decoded=1; continue; }
    case $(( (${#SF_RESUME_TIMES} + ${#SF_RESUME_PAIRS} + ${#SF_RESUME_PREVIEWS}) % 3 )) in
      0) SF_RESUME_TIMES+=( "$field" ) ;;
      1) SF_RESUME_PAIRS+=( "$field" ) ;;
      2) SF_RESUME_PREVIEWS+=( "$field" ) ;;
    esac
  done < <(printf '%s\n' "${lines[@]}" | jq -jRn '
    def one_line: gsub("[[:cntrl:]]"; " ");
    def summary:
      if . == null then "(unreadable)"
      elif .type == "session" then "(empty session)"
      elif .type == "system" then "SYSTEM"
      elif .type == "context" then (.hook | ascii_upcase)
      elif .type == "message" and .role == "user" then
        ([.content[]? | select(.type == "text") | .text] | join(""))
      elif .type == "message" and .role == "assistant" then
        (([.content[]? |
          if .type == "text" then .text
          elif .type == "tool_call" then .name
          else empty end] | last) // "AGENT")
      elif .type == "message" and .role == "tool_result" then
        (.name + (if .exit_code == 0 then "" else
          " exit " + (.exit_code | tostring) end))
      else "(no summary)" end;
    [inputs] as $lines |
    [range(0; ($lines | length) / 2) as $i |
      {header: ($lines[$i * 2] | fromjson? // null),
       last: ($lines[$i * 2 + 1] | fromjson? // null)}] as $rows |
    ($rows[] |
      ((.header.created // "unknown") | tostring | one_line |
        if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}") then
          .[0:16] | sub("T"; " ")
        else . end), "\u0000",
      (((.header.backend.name // "?") | one_line) + "/" +
       ((.header.profile.request.model // "?") | one_line)), "\u0000",
      (.last | summary | one_line), "\u0000"),
    "ok", "\u0000"
  ' 2>/dev/null)
  (( decoded )) || {
    SF_RESUME_PATHS=()
    SF_RESUME_TIMES=()
    SF_RESUME_PAIRS=()
    SF_RESUME_PREVIEWS=()
    sf_resume_fail 'cannot summarize sessions'
    return 1
  }
}

sf_resume_load_page() {
  integer start=$(( SF_RESUME_PAGE * SF_RESUME_LIMIT + 1 ))
  integer end=$(( start + SF_RESUME_LIMIT - 1 ))
  (( end <= ${#SF_RESUME_ALL_PATHS} )) || end=${#SF_RESUME_ALL_PATHS}
  SF_RESUME_SELECTED=1
  sf_resume_load "${(@)SF_RESUME_ALL_PATHS[start,end]}"
}

sf_resume_update_display() {
  local heading output line time pair preview marker footer label
  integer index count=${#SF_RESUME_PATHS} number_width=1
  integer columns=${COLUMNS:-0} available time_width=16 pair_width preview_width
  integer selected_start=0 selected_end=0 footer_start first last total
  (( columns > 1 )) || columns=80
  available=$(( columns - number_width - 5 ))
  (( available >= time_width + 2 )) || time_width=$(( available > 2 ? available - 2 : 1 ))
  available=$(( available - time_width - 2 ))
  (( available > 3 )) || available=4
  pair_width=1
  for pair in "${SF_RESUME_PAIRS[@]}"; do
    (( ${#pair} <= pair_width )) || pair_width=${#pair}
  done
  (( pair_width < available - 2 )) || pair_width=$(( available - 3 ))
  preview_width=$(( available - pair_width - 2 ))

  total=${#SF_RESUME_ALL_PATHS}
  (( total > 0 )) || total=count
  first=$(( SF_RESUME_PAGE * SF_RESUME_LIMIT + 1 ))
  last=$(( first + count - 1 ))
  heading="Resume session ($first - $last of $total)"
  heading=${heading[1,$(( columns - 1 ))]}
  output="$heading"$'\n\n'
  for (( index = 1; index <= count; index++ )); do
    time=$SF_RESUME_TIMES[index]
    pair=$SF_RESUME_PAIRS[index]
    preview=$SF_RESUME_PREVIEWS[index]
    (( ${#time} <= time_width )) || time="${time[1,$(( time_width - 1 ))]}…"
    (( ${#pair} <= pair_width )) || pair="${pair[1,$(( pair_width - 1 ))]}…"
    (( ${#preview} <= preview_width )) || preview="${preview[1,$(( preview_width - 1 ))]}…"
    marker=' '
    (( index != SF_RESUME_SELECTED )) || marker='›'
    label=$(( index % 10 ))
    line="$marker ${(l:number_width:)label}  ${(r:time_width:)time}  ${(r:pair_width:)pair}  ${(r:preview_width:)preview}"
    line=${line[1,$(( columns - 1 ))]}
    output+="$line"$'\n'
    if (( index == SF_RESUME_SELECTED )); then
      selected_start=$(( ${#output} - ${#line} - 1 ))
      selected_end=$(( ${#output} - 1 ))
    fi
  done
  footer='↑/↓ select  ←/→ page  0–9 jump  Enter resumes  Esc cancels'
  (( ${#footer} < columns )) || footer="${footer[1,$(( columns - 2 ))]}…"
  footer_start=$(( ${#output} + 1 ))
  PREDISPLAY="$output"$'\n'"$footer"$'\n'
  POSTDISPLAY=''
  BUFFER=''
  # Attributes are fixed because resume bypasses themed rendering.
  # Offsets index PREDISPLAY, which holds output plus the footer line.
  region_highlight=(
    "P0 ${#heading} bold"
    "P$selected_start $selected_end standout"
    "P$footer_start $(( footer_start + ${#footer} )) fg=8"
  )
  zle reset-prompt 2>/dev/null || true
}

sf_resume_change_page() {
  integer pages=$(( (${#SF_RESUME_ALL_PATHS} + SF_RESUME_LIMIT - 1) / SF_RESUME_LIMIT ))
  if [[ $KEYS == $'\e[D' ]]; then
    (( SF_RESUME_PAGE > 0 )) || return 0
    SF_RESUME_PAGE=$(( SF_RESUME_PAGE - 1 ))
  else
    (( SF_RESUME_PAGE + 1 < pages )) || return 0
    SF_RESUME_PAGE=$(( SF_RESUME_PAGE + 1 ))
  fi
  sf_resume_load_page || return
  sf_resume_update_display
}

sf_resume_move() {
  if [[ $KEYS == $'\e[A' ]]; then
    (( SF_RESUME_SELECTED > 1 )) && SF_RESUME_SELECTED=$(( SF_RESUME_SELECTED - 1 ))
  else
    (( SF_RESUME_SELECTED < ${#SF_RESUME_PATHS} )) &&
      SF_RESUME_SELECTED=$(( SF_RESUME_SELECTED + 1 ))
  fi
  sf_resume_update_display
}

sf_resume_jump() {
  integer choice=$KEYS
  (( choice > 0 )) || choice=10
  (( choice <= ${#SF_RESUME_PATHS} )) || return 0
  SF_RESUME_SELECTED=$choice
  sf_resume_accept
}

sf_resume_accept() {
  BUFFER=$SF_RESUME_SELECTED
  PREDISPLAY=''
  POSTDISPLAY=''
  zle redisplay
  zle accept-line
}

sf_resume_cancel() {
  SF_RESUME_CANCELLED=1
  BUFFER=''
  PREDISPLAY=''
  POSTDISPLAY=''
  zle redisplay
  zle accept-line
}

sf_resume_ignore() {
  return 0
}

# Runs resume in its own editor because ZLE widgets cannot reenter ZLE.
# Returns 130 on cancellation; otherwise places the selected path in REPLY.
sf_resume_run() {
  local choice='' saved_tty=''
  SF_RESUME_CANCELLED=0
  SF_RESUME_ALL_PATHS=( "$@" )
  SF_RESUME_PAGE=0
  SF_RESUME_ERROR=''
  zmodload zsh/zle || {
    sf_resume_fail 'cannot load ZLE'
    return
  }
  sf_resume_load_page || return 1

  zle -N sf_resume_accept
  zle -N sf_resume_cancel
  zle -N sf_resume_move
  zle -N sf_resume_change_page
  zle -N sf_resume_jump
  zle -N sf_resume_ignore
  zle -N zle-line-init sf_resume_update_display
  bindkey -N sf-resume emacs
  bindkey -R -M sf-resume $'\x01-\xff' sf_resume_ignore
  bindkey -M sf-resume '^@' sf_resume_ignore
  bindkey -M sf-resume $'\e[200~' sf_resume_ignore
  bindkey -M sf-resume $'\e[201~' sf_resume_ignore
  bindkey -M sf-resume '^M' sf_resume_accept
  bindkey -M sf-resume '^J' sf_resume_accept
  bindkey -M sf-resume '^C' sf_resume_cancel
  bindkey -M sf-resume '^D' sf_resume_cancel
  bindkey -M sf-resume '^[' sf_resume_cancel
  bindkey -M sf-resume $'\e[A' sf_resume_move
  bindkey -M sf-resume $'\e[B' sf_resume_move
  bindkey -M sf-resume $'\e[D' sf_resume_change_page
  bindkey -M sf-resume $'\e[C' sf_resume_change_page
  local digit
  for digit in {0..9}; do bindkey -M sf-resume "$digit" sf_resume_jump; done

  # ZLE leaves ISIG enabled, so Ctrl-C must be read as editor input.
  saved_tty=$(stty -g 2>/dev/null) || saved_tty=''
  [[ -z $saved_tty ]] || stty intr undef 2>/dev/null || true
  vared -M sf-resume -p '' choice || SF_RESUME_CANCELLED=1
  [[ -z $saved_tty ]] || stty "$saved_tty" 2>/dev/null || true

  (( ! SF_RESUME_CANCELLED )) || return 130
  [[ $choice == <1-> ]] &&
    (( choice <= ${#SF_RESUME_PATHS} )) || {
    sf_resume_fail "invalid session selection: $choice"
    return 1
  }
  REPLY=$SF_RESUME_PATHS[choice]
}
