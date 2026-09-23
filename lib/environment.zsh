emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -g SF_ENVIRONMENT_ERROR=''
typeset -ga SF_ENVIRONMENT_VALUES=()

sf_environment_fail() {
  SF_ENVIRONMENT_ERROR=$1
  return 1
}

# Exported values win over .env in the config directory.
sf_environment_load() {
  local env_file=$1/.env selected=$2 line key value name
  local -a selected_names
  local -A values

  SF_ENVIRONMENT_ERROR=''
  SF_ENVIRONMENT_VALUES=()
  selected_names=( ${=selected} )
  for name in $selected_names; do
    [[ ${parameters[$name]-} == *export* ]] || continue
    values[$name]=${(P)name}
  done
  if (( ${#selected_names} )) &&
    [[ -e $env_file || -L $env_file ]]; then
    [[ -f $env_file && -r $env_file ]] || {
      sf_environment_fail "cannot read env file: $env_file"
      return
    }
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%$'\r'}
      [[ $line =~ '[^[:space:]]' ]] || continue
      [[ $line =~ '^[[:space:]]*#' ]] && continue
      if [[ $line =~ '^[[:space:]]*export[[:space:]]+' ]]; then
        line=${line#${MATCH}}
      fi
      [[ $line == *=* ]] || {
        sf_environment_fail "invalid env file line in $env_file"
        return
      }
      key=${line%%=*}
      key=${key%${key##*[![:space:]]}}
      key=${key#${key%%[![:space:]]*}}
      [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        sf_environment_fail "invalid env name in $env_file: $key"
        return
      }
      (( ${selected_names[(Ie)$key]} )) || continue
      (( ${+values[$key]} )) && continue
      value=${line#*=}
      value=${value#${value%%[![:space:]]*}}
      value=${value%${value##*[![:space:]]}}
      if (( ${#value} >= 2 )) && [[ $value == \"*\" || $value == \'*\' ]]; then
        value=${value[2,-2]}
      fi
      values[$key]=$value
    done <"$env_file"
  fi
  for name in $selected_names; do
    (( ${+values[$name]} )) || continue
    SF_ENVIRONMENT_VALUES+=( "$name=$values[$name]" )
  done
}
