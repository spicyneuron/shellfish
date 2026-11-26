# Shared Agent Skills discovery and loading.

sf_skills_scalar() {
  emulate -L zsh
  setopt extended_glob
  local value=$1 decoded
  value=${value##[[:space:]]#}
  value=${value%%[[:space:]]#}
  case $value in
    \"*\")
      decoded=$(jq -er 'select(type == "string")' <<<"$value" 2>/dev/null) || return 1
      REPLY=$decoded
      ;;
    \'*\')
      [[ $value == *\' && ${#value} -ge 2 ]] || return 1
      value=${value[2,-2]//\'\'/\'}
      REPLY=$value
      ;;
    *)
      [[ -n $value && $value != [\|\>]* ]] || return 1
      REPLY=$value
      ;;
  esac
}

sf_skills_metadata() {
  emulate -L zsh
  setopt extended_glob
  local file=$1 line key value name='' description='' disabled=false
  integer first=1 closed=0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if (( first )); then
      first=0
      [[ $line == '---' ]] || return 1
      continue
    fi
    if [[ $line == '---' ]]; then
      closed=1
      break
    fi
    [[ $line == [[:space:]]# || $line == [[:space:]]#\#* ]] && continue
    [[ $line == ([A-Za-z0-9_-]##):* ]] || continue
    key=${line%%:*}
    value=${line#*:}
    case $key in
      name)
        sf_skills_scalar "$value" || return 1
        name=$REPLY
        ;;
      description)
        sf_skills_scalar "$value" || return 1
        description=$REPLY
        ;;
      disable-model-invocation)
        sf_skills_scalar "$value" || return 1
        case ${REPLY:l} in
          true) disabled=true ;;
          false) disabled=false ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done <"$file"
  (( closed )) || return 1
  [[ $name == [a-z0-9]##(-[a-z0-9]##)# && ${#name} -le 64 ]] || return 1
  [[ ${file:h:t} == $name ]] || return 1
  [[ -n $description && ${#description} -le 1024 && $description != *$'\0'* ]] || return 1
  reply=( "$name" "$description" "$disabled" )
}

# Populates reply with name, description, and canonical SKILL.md path triplets.
sf_skills_discover() {
  emulate -L zsh
  setopt extended_glob
  local config_dir=${1-} project_dir=${2:-$PWD} include_disabled=${3:-false} selection
  local root canonical directory file name description disabled
  local -a roots discovered allowed
  local -A seen_roots seen_names
  selection=$(jq -r '
    if has("skills") then
      .skills |
      if type == "array" and all(.[];
        type == "string" and length <= 64 and test("^[a-z0-9]+(-[a-z0-9]+)*\\z"))
      then .[] else error("config.skills must be an array of skill names") end
    else "*" end
  ' <<<"${SHELLFISH_CONFIG:-{\}}") || return 1
  allowed=( ${(f)selection} )
  roots=( "$project_dir/.agents/skills" )
  if [[ -n $config_dir ]]; then
    roots+=( "$config_dir/skills" )
    # A .shellfish directory shares skills with its sibling .agents directory.
    [[ ${config_dir:t} != .shellfish ]] || roots+=( "${config_dir:h}/.agents/skills" )
  fi
  for root in "${roots[@]}"; do
    canonical=${root:A}
    [[ -z ${seen_roots[$canonical]-} ]] || continue
    seen_roots[$canonical]=1
    [[ -d $canonical ]] || continue
    for directory in "$canonical"/*(N-/); do
      file=$directory/SKILL.md
      [[ -f $file && -r $file ]] || continue
      sf_skills_metadata "$file" || continue
      name=$reply[1]
      description=$reply[2]
      disabled=$reply[3]
      [[ -z ${seen_names[$name]-} ]] || continue
      seen_names[$name]=1
      [[ $disabled == false || $include_disabled == true ]] || continue
      [[ $selection == '*' || ${allowed[(Ie)$name]} -gt 0 ]] || continue
      discovered+=( "$name" "$description" "${file:A}" )
    done
  done
  reply=( "${discovered[@]}" )
}

# REPLY is the skill's instructions after its frontmatter.
sf_skills_body() {
  emulate -L zsh
  local line
  REPLY=''
  {
    IFS= read -r line || return 1
    while IFS= read -r line || [[ -n $line ]]; do
      [[ ${line%$'\r'} == --- ]] && break
    done
    while IFS= read -r line || [[ -n $line ]]; do
      REPLY+=$line$'\n'
    done
  } <"$1"
}

# Wrap BODY, which ends in a newline unless empty, as the model sees a loaded skill.
sf_skills_wrap() {
  jq -nr --arg name "$1" --arg directory "$2" --arg body "$3" '
    "<skill name=\"" + ($name | @html) + "\" directory=\"" +
    ($directory | @html) + "\">\n" + $body + "</skill>"'
}

# Print wrapped instructions for NAME. Return 2 if unavailable, 1 on failure.
sf_skills_load() {
  local name=$1 file REPLY
  local -a reply
  integer index
  sf_skills_discover "${SHELLFISH_DIR-}" "$PWD" "${2:-false}" || return 1
  for (( index = 1; index <= ${#reply}; index += 3 )); do
    [[ $reply[index] == "$name" ]] || continue
    file=$reply[index+2]
    sf_skills_body "$file" || return 1
    sf_skills_wrap "$name" "${file:h}" "$REPLY" || return 1
    return 0
  done
  return 2
}
