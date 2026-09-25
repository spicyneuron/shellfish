emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -g SF_ENVIRONMENT_ERROR=''
typeset -ga SF_ENVIRONMENT_VALUES=()

sf_environment_fail() {
  SF_ENVIRONMENT_ERROR=$1
  return 1
}

sf_environment_config_dir() {
  local base=${XDG_CONFIG_HOME:-${HOME:+$HOME/.config}}
  [[ -n $base ]] || sf_environment_fail 'HOME or XDG_CONFIG_HOME is required' || return
  REPLY=${base:A}/shellfish
}

# Exported values win over profile env, then .env in the config directory.
# Without selected names every entry loads; otherwise only the named entries.
sf_environment_load() {
  local env_file line key value name profile_env=${2:-'{}'}
  local -a selected_names=( ${=1-} )
  integer all=$(( ${#selected_names} == 0 ))
  local -A values

  SF_ENVIRONMENT_ERROR=''
  SF_ENVIRONMENT_VALUES=()
  sf_environment_config_dir || return
  env_file=$REPLY/.env
  for name in $selected_names; do
    [[ ${parameters[$name]-} == *export* ]] || continue
    values[$name]=${(P)name}
  done
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    (( all || ${selected_names[(Ie)$key]} )) || continue
    [[ ${parameters[$key]-} == *export* ]] && continue
    values[$key]=$value
  done < <(jq -j 'to_entries[] | .key, "\u0000", .value, "\u0000"' <<<"$profile_env")
  if (( all || ${#selected_names} )) &&
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
      (( all || ${selected_names[(Ie)$key]} )) || continue
      (( ${+values[$key]} )) && continue
      [[ ${parameters[$key]-} == *export* ]] && continue
      value=${line#*=}
      value=${value#${value%%[![:space:]]*}}
      value=${value%${value##*[![:space:]]}}
      if (( ${#value} >= 2 )) && [[ $value == \"*\" || $value == \'*\' ]]; then
        value=${value[2,-2]}
      fi
      values[$key]=$value
    done <"$env_file"
  fi
  for name in ${(k)values}; do
    SF_ENVIRONMENT_VALUES+=( "$name=$values[$name]" )
  done
}
