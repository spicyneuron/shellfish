# Shared Agent Skills discovery for bundled hook scripts and tools.

sf_skills_scalar() {
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
  local bundled_root=$1 config_dir=${2-} project_dir=${3:-$PWD}
  local home=${HOME-} root canonical directory file name description disabled
  local -a roots discovered
  local -A seen_roots seen_names
  roots=( "$project_dir/.agents/skills" )
  [[ -z $config_dir ]] || roots+=( "$config_dir/skills" )
  [[ -z $home ]] || roots+=( "$home/.agents/skills" )
  roots+=( "$bundled_root/skills" )
  for root in "${roots[@]}"; do
    canonical=${root:A}
    [[ -z ${seen_roots[$canonical]-} ]] || continue
    seen_roots[$canonical]=1
    [[ -d $canonical ]] || continue
    for directory in "$canonical"/*(N/); do
      file=$directory/SKILL.md
      [[ -f $file && -r $file ]] || continue
      sf_skills_metadata "$file" || continue
      name=$reply[1]
      description=$reply[2]
      disabled=$reply[3]
      [[ -z ${seen_names[$name]-} ]] || continue
      seen_names[$name]=1
      [[ $disabled == false ]] || continue
      discovered+=( "$name" "$description" "${file:A}" )
    done
  done
  reply=( "${discovered[@]}" )
}
