emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -ga SF_PRESENT_HIGHLIGHT_SPANS=()
typeset -g SF_PRESENT_HIGHLIGHT_ERROR=''
# Set when a scan ends on an inline construct that a later row may still close.
# Other modes are carried in the scan state instead and never withhold a row:
# they change which rules apply until something closes them.
typeset -gi SF_PRESENT_HIGHLIGHT_INLINE_OPEN=0 SF_PRESENT_HIGHLIGHT_BLOCK_OPEN=0
# Semantic styles keyed by row kind and by transient chrome name. Row kinds fall
# back from "type.role" to "type". An empty map disables all styling.
typeset -gA SF_PRESENT_STYLE=()
typeset -g SF_PRESENT_BACKGROUND=''
typeset -gi SF_PRESENT_HIGHLIGHT_ENABLED=0
# Cached syntax spans per node, parallel to the presentation nodes but
# deliberately outside them: nodes stay semantic, these are colors.
typeset -ga SF_PRESENT_HIGHLIGHT_CACHE=()
typeset -ga SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE=() SF_PRESENT_HIGHLIGHT_CACHE_STATE=()
# START is the first retained source offset. STATE is the scan mode in force at
# the node's frontier, which is where the next scan resumes.
typeset -ga SF_PRESENT_HIGHLIGHT_CACHE_START=()
# The scan mode a pending scan would leave behind, and whether the last release
# moved a frontier and so needs the rows projected again.
typeset -g SF_PRESENT_HIGHLIGHT_NEXT_STATE=''
typeset -gi SF_PRESENT_HIGHLIGHT_ADVANCED=0

# Returns light or dark from the terminal's OSC 11 default-background reply. A
# terminal that does not implement OSC 11 cannot hold startup indefinitely.
sf_chat_background_mode() {
  local tty saved answer='' character previous=''
  integer index red green blue luminance
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  { exec {tty}<>/dev/tty } 2>/dev/null || return 1
  saved=$(stty -g <&$tty) || { exec {tty}>&-; return 1; }
  if ! stty -echo -icanon min 0 time 1 <&$tty; then
    exec {tty}>&-
    return 1
  fi
  printf '\e]11;?\a' >&$tty
  # OSC replies end in either BEL or ST. Bound both the reply length and the
  # wait: nothing beyond an RGB OSC 11 response is useful here.
  for (( index = 0; index < 64; index++ )); do
    IFS= read -r -k 1 -t 0.05 -u $tty character || break
    answer+=$character
    if [[ $character == $'\a' || ( $previous == $'\e' && $character == \\ ) ]]; then
      break
    fi
    previous=$character
  done
  stty "$saved" <&$tty 2>/dev/null || true
  exec {tty}>&-

  # OSC 11 specifies RGB components at any equal precision. Use the first two
  # hex digits of each component.
  [[ $answer =~ $'\e]11;rgb:'([[:xdigit:]]{2})[[:xdigit:]]*/([[:xdigit:]]{2})[[:xdigit:]]*/([[:xdigit:]]{2}) ]] ||
    return 1
  red=$(( 16#${match[1]} ))
  green=$(( 16#${match[2]} ))
  blue=$(( 16#${match[3]} ))
  luminance=$(( 2126 * red + 7152 * green + 722 * blue ))
  if (( luminance >= 1280000 )); then REPLY=light; else REPLY=dark; fi
}

# Resolve the active palette into semantic styles.
# Leaves everything empty when the terminal or environment refuses color.
sf_chat_theme_config() {
  local presentation=${1:-\{\}} mode key value
  local -A values

  SF_PRESENT_STYLE=()
  SF_PRESENT_HIGHLIGHT_ERROR=''
  SF_PRESENT_HIGHLIGHT_ENABLED=0
  [[ ${TERM-} != dumb && -z ${NO_COLOR-} ]] || return 0
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    values[$key]=$value
  done < <(jq -j '
    def styles($name):
      .themes[$name] |
      {message:(if .text then "fg=" + .text else "" end),
       "section.user":("fg=" + .user_heading + ",bold"),
       "section.agent":("fg=" + .agent_heading + ",bold"),
       "section.system":("fg=" + .system_heading + ",bold"),
       "message.system":("fg=" + .context),
       reasoning:("fg=" + .reasoning),
       tool_call:("fg=" + .tool), tool_result:("fg=" + .tool),
       injection:("fg=" + .context),
       notice:("fg=" + .muted), "notice.error":("fg=" + .error),
       activity:("fg=" + .muted), divider:("fg=" + .divider),
       footer:("fg=" + .footer), prompt:("fg=" + .prompt),
       permission:("fg=" + .permission + ",bold"),
       muted:("fg=" + .muted),
       "syntax.comment":("fg=" + .syntax_comment),
       "syntax.string":("fg=" + .syntax_string),
       "syntax.number":("fg=" + .syntax_number),
       "syntax.keyword":("fg=" + .syntax_keyword),
       "syntax.tag":("fg=" + .syntax_tag),
       "syntax.link":("fg=" + .user_heading + ",underline"),
       "syntax.code":("fg=" + .user_heading),
       "syntax.strong":"bold", "syntax.em":"underline",
       "syntax.added":("fg=" + .diff_added + ",bg=" + .diff_added_background),
       "syntax.removed":("fg=" + .diff_removed + ",bg=" + .diff_removed_background)};
    def record($key; $value): $key, "\u0000", $value, "\u0000";
    record("mode"; .theme_mode),
    (styles(.theme_light) | to_entries[] | record("light." + .key; .value)),
    (styles(.theme_dark) | to_entries[] | record("dark." + .key; .value)),
    record("valid"; "yes")
  ' <<<"$presentation" 2>/dev/null)
  [[ ${values[valid]-} == yes ]] || {
    SF_PRESENT_HIGHLIGHT_ERROR='cannot apply configured theme'
    return 1
  }

  mode=$values[mode]
  if [[ $mode == auto ]]; then
    # Probing queries the terminal in raw mode, so it happens once per process
    # rather than on every presentation change.
    [[ -n $SF_PRESENT_BACKGROUND ]] ||
      { sf_chat_background_mode && SF_PRESENT_BACKGROUND=$REPLY } ||
      SF_PRESENT_BACKGROUND=dark
    mode=$SF_PRESENT_BACKGROUND
  fi

  # Palettes and syntax spans are hex. Terminals without direct color need the
  # approximation module, which would otherwise downgrade true color output.
  if [[ ${COLORTERM-} != (truecolor|24bit) ]]; then
    zmodload zsh/nearcolor 2>/dev/null || {
      SF_PRESENT_HIGHLIGHT_ERROR='cannot load zsh/nearcolor'
      return 1
    }
  fi
  for key in ${(k)values}; do
    [[ $key == $mode.* ]] || continue
    SF_PRESENT_STYLE[${key#$mode.}]=$values[$key]
  done
  SF_PRESENT_HIGHLIGHT_ENABLED=1
}

# Drops the oldest $1 cache entries so they stay aligned with the nodes they
# describe. Dropping every entry is how a transcript rebuild clears the cache.
sf_chat_highlight_drop() {
  integer count=$1
  (( count > 0 )) || return 0
  if (( count >= ${#SF_PRESENT_HIGHLIGHT_CACHE} )); then
    SF_PRESENT_HIGHLIGHT_CACHE=()
    SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE=()
    SF_PRESENT_HIGHLIGHT_CACHE_STATE=()
    SF_PRESENT_HIGHLIGHT_CACHE_START=()
    return 0
  fi
  SF_PRESENT_HIGHLIGHT_CACHE=( "${(@)SF_PRESENT_HIGHLIGHT_CACHE[count + 1,-1]}" )
  SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE=(
    "${(@)SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[count + 1,-1]}" )
  SF_PRESENT_HIGHLIGHT_CACHE_STATE=(
    "${(@)SF_PRESENT_HIGHLIGHT_CACHE_STATE[count + 1,-1]}" )
  SF_PRESENT_HIGHLIGHT_CACHE_START=(
    "${(@)SF_PRESENT_HIGHLIGHT_CACHE_START[count + 1,-1]}" )
}

# Retains only spans still ahead of a flushed boundary. Flushed rows are gone
# from the viewport, so the source behind them cannot be styled again.
sf_chat_highlight_prune() {
  integer node=$1 offset=$2 index start end
  local -a spans=()
  (( node > 0 && node <= ${#SF_PRESENT_NODE_TYPE} && offset >= 0 &&
      offset <= ${#SF_PRESENT_NODE_BODY[node]} )) || return 1
  [[ -n ${SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[node]-} ]] || return 0
  (( offset > ${SF_PRESENT_HIGHLIGHT_CACHE_START[node]:-0} )) || return 0
  SF_PRESENT_HIGHLIGHT_SPANS=( ${(s: :)${SF_PRESENT_HIGHLIGHT_CACHE[node]-}} )
  for (( index = 1; index <= ${#SF_PRESENT_HIGHLIGHT_SPANS}; index += 3 )); do
    start=${SF_PRESENT_HIGHLIGHT_SPANS[index]}
    end=${SF_PRESENT_HIGHLIGHT_SPANS[index + 1]}
    (( end > offset )) || continue
    (( start >= offset )) || start=$offset
    spans+=( $start $end "${SF_PRESENT_HIGHLIGHT_SPANS[index + 2]}" )
  done
  SF_PRESENT_HIGHLIGHT_CACHE[node]="${(j: :)spans}"
  SF_PRESENT_HIGHLIGHT_CACHE_START[node]=$offset
}

# Scans one bounded segment, resuming at the node's frontier. Committed source
# is never revisited, so the scan mode is carried across the boundary instead
# of being recovered by rescanning the line that produced it.
sf_chat_highlight_scan() {
  integer node=$1 target=$2 frontier continuation=0
  local body=$SF_PRESENT_NODE_BODY[node] language segment state
  SF_PRESENT_HIGHLIGHT_SPANS=()
  SF_PRESENT_HIGHLIGHT_INLINE_OPEN=0
  # Cleared before the early return: a node that scans nothing must not leave
  # the previous node's scan mode standing for its own commit to store.
  SF_PRESENT_HIGHLIGHT_NEXT_STATE=''
  frontier=${SF_PRESENT_NODE_FRONTIER[node]:--1}
  (( frontier >= 0 )) || frontier=0
  (( target > frontier )) || return 0
  language=${SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[node]-}
  segment=${body[frontier + 1,target]}
  state=${SF_PRESENT_HIGHLIGHT_CACHE_STATE[node]-}
  (( frontier == 0 )) || [[ ${body[frontier]} == $'\n' ]] || continuation=1
  case $language in
    markdown)
      sf_chat_markdown_highlight "$segment" $frontier "$state" $continuation
      SF_PRESENT_HIGHLIGHT_NEXT_STATE=$REPLY
      ;;
    diff) sf_chat_diff_highlight "$segment" $frontier ;;
    plain) ;;
    *)
      sf_chat_code_highlight "$segment" "$language" $frontier "${state:-0}"
      SF_PRESENT_HIGHLIGHT_NEXT_STATE=$SF_PRESENT_HIGHLIGHT_BLOCK_OPEN
      ;;
  esac
}

# Appends the scanned spans and releases the boundary they cover. The guard
# reads the frontier unset rather than treating it as zero, so a node with
# nothing to scan yet still moves from unset to zero here. That is what lets
# wrapping start reporting row boundaries for it at all.
sf_chat_highlight_commit() {
  integer node=$1 target=$2 retain index start end
  local -a spans
  (( target > ${SF_PRESENT_NODE_FRONTIER[node]:--1} )) || return 0
  retain=${SF_PRESENT_HIGHLIGHT_CACHE_START[node]:-0}
  spans=( ${(s: :)${SF_PRESENT_HIGHLIGHT_CACHE[node]-}} )
  for (( index = 1; index <= ${#SF_PRESENT_HIGHLIGHT_SPANS}; index += 3 )); do
    start=${SF_PRESENT_HIGHLIGHT_SPANS[index]}
    end=${SF_PRESENT_HIGHLIGHT_SPANS[index + 1]}
    (( end > retain )) || continue
    (( start >= retain )) || start=$retain
    spans+=( $start $end "${SF_PRESENT_HIGHLIGHT_SPANS[index + 2]}" )
  done
  SF_PRESENT_HIGHLIGHT_CACHE[node]="${(j: :)spans}"
  SF_PRESENT_HIGHLIGHT_CACHE_STATE[node]=$SF_PRESENT_HIGHLIGHT_NEXT_STATE
  sf_chat_set_frontier $node $target
}

# Releases one filled visual row of a growing line. A row ending inside an
# inline construct is withheld so the next row can close it, up to a limit the
# caller sizes from the viewport: a flushed row can never be restyled.
sf_chat_highlight_rows() {
  integer node=$1 boundary=$2 limit=$3 frontier
  SF_PRESENT_HIGHLIGHT_ADVANCED=0
  (( SF_PRESENT_HIGHLIGHT_ENABLED )) || return 0
  (( node > 0 && node <= ${#SF_PRESENT_NODE_TYPE} )) || return 1
  # Only Markdown resumes mid-line; a code or diff line is styled as a whole.
  [[ ${SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[node]-} == markdown ]] || return 0
  frontier=${SF_PRESENT_NODE_FRONTIER[node]:--1}
  (( frontier >= 0 && boundary > frontier &&
      boundary <= ${#SF_PRESENT_NODE_BODY[node]} )) || return 0
  sf_chat_highlight_scan $node $boundary || return 1
  (( ! SF_PRESENT_HIGHLIGHT_INLINE_OPEN || boundary - frontier > limit )) || return 0
  sf_chat_highlight_commit $node $boundary || return 1
  SF_PRESENT_HIGHLIGHT_ADVANCED=1
}

# Append one zero-based semantic span when its configured style is active.
sf_chat_highlight_span() {
  integer start=$1 end=$2
  local style=${SF_PRESENT_STYLE[syntax.$3]-}
  (( end > start )) && [[ -n $style ]] || return 0
  SF_PRESENT_HIGHLIGHT_SPANS+=( $start $end "$style" )
}

# Highlight enough of common languages to distinguish comments, strings,
# numbers, reserved words, and markup tags. Unknown languages remain plain text.
sf_chat_code_highlight() {
  local source=$1 language=$2 quotes='"' line_comment='' block_start='' block_end=''
  local block_kind=comment words='' character quote token
  integer base=${3:-0} state=${4:-0} length=${#source} index=1 end escaped closed

  SF_PRESENT_HIGHLIGHT_BLOCK_OPEN=0
  case $language in
    javascript|typescript|ts|jsx|tsx|node) language=js ;;
    bash|zsh|shell|console) language=sh ;;
    py) language=python ;;
    yml) language=yaml ;;
    jsonc) language=json ;;
    xml|svg) language=html ;;
  esac
  case $language in
    js)
      line_comment=// block_start='/*' block_end='*/' quotes="\"'"; quotes+='`'
      words='async|await|boolean|break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|from|function|if|implements|import|in|instanceof|interface|let|new|null|number|of|private|protected|public|readonly|return|string|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|yield'
      ;;
    sh)
      line_comment='#' quotes="\"'"
      words='case|do|done|elif|else|esac|export|fi|for|function|if|in|local|return|then|until|while'
      ;;
    go)
      line_comment=// block_start='/*' block_end='*/' quotes="\"'"; quotes+='`'
      words='break|case|chan|const|continue|default|defer|else|fallthrough|false|for|func|go|goto|if|import|interface|map|nil|package|range|return|select|struct|switch|true|type|var'
      ;;
    python)
      line_comment='#' block_start='"""' block_end='"""' block_kind=string quotes="\"'"
      words='and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield'
      ;;
    json)
      line_comment=// block_start='/*' block_end='*/'
      words='true|false|null'
      ;;
    yaml)
      line_comment='#' quotes="\"'" words='true|false|null'
      ;;
    css)
      block_start='/*' block_end='*/' quotes="\"'"
      ;;
    html)
      block_start='<!--' block_end='-->' quotes="\"'"
      ;;
    *) return 0 ;;
  esac

  if (( state )) && [[ -n $block_end ]]; then
    end=1
    while (( end <= length )) &&
        [[ ${source[end,end + ${#block_end} - 1]} != $block_end ]]; do
      (( ++end ))
    done
    if (( end <= length )); then
      (( end += ${#block_end} ))
    else
      end=$(( length + 1 ))
      SF_PRESENT_HIGHLIGHT_BLOCK_OPEN=1
    fi
    sf_chat_highlight_span $base $(( base + end - 1 )) $block_kind
    index=$end
  fi
  while (( index <= length )); do
    character=${source[index]}
    if [[ $language == yaml ]] && { (( index == 1 )) || [[ ${source[index - 1]} == $'\n' ]]; }; then
      end=$index
      while (( end <= length )) && [[ ${source[end]} == [[:blank:]] ]]; do (( ++end )); done
      integer key_start=$end
      while (( end <= length )) && [[ ${source[end]} == [A-Za-z0-9_.-] ]]; do (( ++end )); done
      integer key_end=$end
      while (( end <= length )) && [[ ${source[end]} == [[:blank:]] ]]; do (( ++end )); done
      if (( key_end > key_start )) && [[ ${source[end]} == : ]]; then
        sf_chat_highlight_span $(( base + key_start - 1 )) $(( base + key_end - 1 )) tag
        index=$key_end
        continue
      fi
    fi
    if [[ -n $block_start && ${source[index,index + ${#block_start} - 1]} == $block_start ]]; then
      end=$(( index + ${#block_start} ))
      while (( end <= length )) &&
          [[ ${source[end,end + ${#block_end} - 1]} != $block_end ]]; do
        (( ++end ))
      done
      if (( end <= length )); then
        (( end += ${#block_end} ))
      else
        end=$(( length + 1 ))
        SF_PRESENT_HIGHLIGHT_BLOCK_OPEN=1
      fi
      sf_chat_highlight_span $(( base + index - 1 )) $(( base + end - 1 )) $block_kind
      index=$end
      continue
    fi
    if [[ -n $line_comment &&
        ${source[index,index + ${#line_comment} - 1]} == $line_comment ]]; then
      end=$index
      while (( end <= length )) && [[ ${source[end]} != $'\n' ]]; do (( ++end )); done
      sf_chat_highlight_span $(( base + index - 1 )) $(( base + end - 1 )) comment
      index=$end
      continue
    fi
    if [[ $quotes == *"$character"* ]]; then
      quote=$character
      end=$(( index + 1 ))
      escaped=0
      closed=0
      while (( end <= length )); do
        character=${source[end]}
        if (( escaped )); then
          escaped=0
        elif [[ $character == \\ ]]; then
          escaped=1
        elif [[ $character == $quote ]]; then
          (( ++end ))
          closed=1
          break
        fi
        (( ++end ))
      done
      if (( closed )); then
        sf_chat_highlight_span $(( base + index - 1 )) $(( base + end - 1 )) string
        index=$end
        continue
      fi
    fi
    if [[ $language == html && $character == '<' &&
        ${source[index + 1]} == [A-Za-z/] ]]; then
      end=$(( index + 2 ))
      while (( end <= length )) && [[ ${source[end]} == [A-Za-z0-9_:-] ]]; do
        (( ++end ))
      done
      sf_chat_highlight_span $(( base + index - 1 )) $(( base + end - 1 )) tag
      index=$end
      continue
    fi
    if [[ $character == [[:digit:]] ]]; then
      end=$(( index + 1 ))
      while (( end <= length )) && [[ ${source[end]} == [[:alnum:]_.] ]]; do
        (( ++end ))
      done
      sf_chat_highlight_span $(( base + index - 1 )) $(( base + end - 1 )) number
      index=$end
      continue
    fi
    if [[ $character == [A-Za-z_] ]]; then
      end=$(( index + 1 ))
      while (( end <= length )) && [[ ${source[end]} == [A-Za-z0-9_] ]]; do
        (( ++end ))
      done
      token=${source[index,end - 1]}
      if [[ -n $words && "|$words|" == *"|$token|"* ]]; then
        sf_chat_highlight_span $(( base + index - 1 )) $(( base + end - 1 )) keyword
      fi
      index=$end
      continue
    fi
    (( ++index ))
  done
}

# Scans Markdown from a boundary that may fall mid-line. $3 carries the scan
# mode across that boundary and $4 marks the source as the continuation of a line
# already scanned, so line-leading syntax is not matched against a fragment.
# Returns the scan mode in REPLY. An unclosed inline construct is reported
# separately because it is the only state for which a caller withholds a row.
sf_chat_markdown_highlight() {
  local source=$1 state=${3-} line fence='' delimiter='' language='' close
  local character suffix rest kind boundary=$state
  integer base_offset=${2:-0} continuation=${4:-0}
  integer length=${#source} index=1 end base close_start
  integer cursor inline_end count content match_end inline complete_line starts_line
  integer comment=0 heading=0
  local -a fields lines
  if [[ $state == heading ]]; then
    heading=1
  elif [[ -n $state ]]; then
    fields=( "${(@ps:\t:)state}" )
    fence=${fields[1]-}
    language=${fields[2]-}
    comment=${fields[3]:-0}
  fi
  SF_PRESENT_HIGHLIGHT_INLINE_OPEN=0
  # One split keeps the scan linear in the segment. A trailing newline leaves an
  # empty final field that stands for no line, so only a non-empty one is kept.
  lines=( "${(@ps:\n:)source}" )
  [[ -n $lines[-1] ]] || lines[-1]=()
  for line in "${lines[@]}"; do
    end=$(( index + ${#line} ))
    base=$(( base_offset + index - 1 ))
    complete_line=$(( end <= length ))
    inline=1
    # A fence opens or closes only on a whole line, so a continuation fragment
    # stays inside whatever mode it inherited.
    starts_line=$(( index > 1 || ! continuation ))
    if [[ -n $fence ]]; then
      inline=0
      close=$line
      close_start=1
      while (( close_start <= ${#close} )) &&
          [[ ${close[close_start]} == (' '|$'\t') ]]; do
        (( ++close_start ))
      done
      if (( starts_line )) && [[ ${close[close_start,-1]} == "$fence"* ]]; then
        sf_chat_highlight_span $base $(( base + ${#line} )) markup
        fence=''
        language=''
        comment=0
      else
        sf_chat_code_highlight "$line" "$language" $base $comment
        comment=$SF_PRESENT_HIGHLIGHT_BLOCK_OPEN
      fi
    elif (( starts_line )) && [[ $line =~ '^ {0,3}(```+|~~~+)[[:space:]]*([^[:space:]]*)' ]]; then
      fence=$match[1]
      language=$match[2]
      sf_chat_highlight_span $base $(( base + ${#line} )) markup
      inline=0
    fi
    if (( inline )); then
      if (( heading )); then
        sf_chat_highlight_span $base $(( base + ${#line} )) strong
      elif (( starts_line )) &&
          [[ $line =~ '^( {0,3})(#{1,6}|>|[-*+]|[0-9]{1,9}[.)])([[:space:]]+)' ]]; then
        match_end=$MEND
        sf_chat_highlight_span $(( base + ${#match[1]} )) $(( base + match_end )) markup
        if [[ $match[2] == \#* ]]; then
          heading=1
          boundary=heading
          sf_chat_highlight_span $(( base + match_end )) $(( base + ${#line} )) strong
        fi
        line=${line[match_end + 1,-1]}
        (( base += match_end ))
      fi
      # Inline syntax never spans a newline, so each line decides this afresh.
      SF_PRESENT_HIGHLIGHT_INLINE_OPEN=0
      cursor=1
      # A line holding no delimiter has nothing for the scan below to find.
      [[ $line == *[\`\*_\[]* ]] || cursor=$(( ${#line} + 1 ))
      while (( cursor <= ${#line} )); do
        character=${line[cursor]}
        if [[ $character == '`' ]]; then
          inline_end=$cursor
          while (( inline_end <= ${#line} )) && [[ ${line[inline_end]} == '`' ]]; do
            (( ++inline_end ))
          done
          delimiter=${line[cursor,inline_end - 1]}
          suffix=${line[inline_end,-1]}
          if [[ $suffix == *"$delimiter"* ]]; then
            rest=${suffix#*"$delimiter"}
            content=$(( ${#line} - ${#rest} - ${#delimiter} + 1 ))
            sf_chat_highlight_span $(( base + cursor - 1 )) \
              $(( base + inline_end - 1 )) markup
            sf_chat_highlight_span $(( base + inline_end - 1 )) \
              $(( base + content - 1 )) code
            sf_chat_highlight_span $(( base + content - 1 )) \
              $(( base + content + ${#delimiter} - 1 )) markup
            cursor=$(( content + ${#delimiter} ))
            continue
          fi
          # A delimiter with no close yet may still be closed by the next row.
          [[ -n $suffix && $suffix[1] == ' ' ]] || SF_PRESENT_HIGHLIGHT_INLINE_OPEN=1
        fi
        if [[ $character == '[' && ${line[cursor,-1]} =~ '^\[[^]]+\]\([^[:space:])]+\)' ]]; then
          match_end=${#MATCH}
          sf_chat_highlight_span $(( base + cursor - 1 )) \
            $(( base + cursor + match_end - 1 )) link
          (( cursor += match_end ))
          continue
        fi
        delimiter=''
        if [[ ${line[cursor,cursor + 1]} == ('**'|'__') ]]; then
          delimiter=${line[cursor,cursor + 1]}
          count=2
        elif [[ $character == ('*'|'_') ]]; then
          delimiter=$character
          count=1
        fi
        if [[ -n $delimiter ]]; then
          suffix=${line[cursor + count,-1]}
          if [[ $suffix == *"$delimiter"* ]]; then
            rest=${suffix#*"$delimiter"}
            content=$(( ${#line} - ${#rest} - count + 1 ))
            sf_chat_highlight_span $(( base + cursor - 1 )) \
              $(( base + cursor + count - 1 )) markup
            (( count == 2 )) && kind=strong || kind=em
            sf_chat_highlight_span $(( base + cursor + count - 1 )) \
              $(( base + content - 1 )) $kind
            sf_chat_highlight_span $(( base + content - 1 )) \
              $(( base + content + count - 1 )) markup
            cursor=$(( content + count ))
            continue
          fi
          [[ -n $suffix && $suffix[1] == ' ' ]] || SF_PRESENT_HIGHLIGHT_INLINE_OPEN=1
        fi
        (( ++cursor ))
      done
    fi
    # The scan mode is reported for the last complete line, which is where a
    # caller resumes. A completed line also closes any inline construct left
    # dangling on it.
    if (( complete_line )); then
      if [[ -n $fence ]] && (( ! inline )); then
        boundary="$fence"$'\t'"$language"$'\t'"$comment"
      else
        boundary=''
      fi
      heading=0
      SF_PRESENT_HIGHLIGHT_INLINE_OPEN=0
    fi
    index=$(( end + 1 ))
  done
  REPLY=$boundary
}

sf_chat_diff_highlight() {
  local source=$1 line kind
  integer base=${2:-0} length=${#source} index=1 end
  while (( index <= length )); do
    end=$index
    while (( end <= length )) && [[ ${source[end]} != $'\n' ]]; do (( ++end )); done
    line=${source[index,end - 1]}
    kind=''
    if [[ $line == '+'* && $line != '+++'* ]]; then kind=added
    elif [[ $line == '-'* && $line != '---'* ]]; then kind=removed
    elif [[ $line == '@@'* ]]; then kind=markup
    fi
    [[ -z $kind ]] || sf_chat_highlight_span $(( base + index - 1 )) $(( base + end - 1 )) $kind
    index=$(( end <= length ? end + 1 : length + 1 ))
  done
}

# Advances every node's highlighting through its last complete line. A line that
# is still growing is left alone here; only a filled visual row releases part of
# one, through sf_chat_highlight_rows.
sf_chat_highlight_update() {
  integer node target
  local body complete language
  (( SF_PRESENT_HIGHLIGHT_ENABLED )) || return 0

  for (( node = 1; node <= ${#SF_PRESENT_NODE_TYPE}; node++ )); do
    case $SF_PRESENT_NODE_TYPE[node] in
      message|reasoning|injection) language=markdown ;;
      tool_call) language=${SF_PRESENT_NODE_FORMAT[node]:-json} ;;
      tool_result)
        [[ $SF_PRESENT_NODE_FORMAT[node] == file_diff ]] && language=diff || language=plain
        ;;
      *) continue ;;
    esac
    # A node's format is fixed when it is created, so this only ever runs the
    # first time a node is seen, when its frontier is still unset.
    if [[ ${SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[node]-} != $language ]]; then
      SF_PRESENT_HIGHLIGHT_CACHE[node]=''
      SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[node]=$language
      SF_PRESENT_HIGHLIGHT_CACHE_STATE[node]=''
      SF_PRESENT_HIGHLIGHT_CACHE_START[node]=0
    fi
    body=$SF_PRESENT_NODE_BODY[node]
    if [[ $SF_PRESENT_NODE_STATE[node] == closed ]]; then
      target=${#body}
    else
      complete=${body%$'\n'*}
      [[ $complete == $body ]] && target=0 || target=$(( ${#complete} + 1 ))
    fi
    sf_chat_highlight_scan $node $target || return 1
    sf_chat_highlight_commit $node $target || return 1
  done
}
