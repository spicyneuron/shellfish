emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -g SF_ENVIRONMENT_ERROR=''
typeset -ga SF_ENVIRONMENT_VALUES=()

sf_environment_fail() {
  SF_ENVIRONMENT_ERROR=$1
  return 1
}

# The Shellfish directory holds configuration, credentials, and sessions. It is
# SHELLFISH_DIR, else the nearest .shellfish above the working directory, else
# ~/.shellfish.
sf_environment_dir() {
  [[ -z ${SHELLFISH_DIR-} ]] || { REPLY=${SHELLFISH_DIR:A}; return; }
  local dir=${PWD:A}
  while [[ ! -d $dir/.shellfish && $dir != / ]]; do dir=${dir:h}; done
  [[ ! -d $dir/.shellfish ]] || { REPLY=$dir/.shellfish; REPLY=${REPLY:A}; return; }
  [[ -n ${HOME-} ]] || sf_environment_fail 'HOME or SHELLFISH_DIR is required' || return
  REPLY=${HOME:A}/.shellfish
}

# Exported values win over .env. No arguments load all entries. An explicit
# selection loads only named entries, even when empty.
sf_environment_load() {
  local env_file line key value name
  local -a selected_names=( ${=1-} )
  integer all=$(( $# == 0 ))
  local -A values

  SF_ENVIRONMENT_ERROR=''
  SF_ENVIRONMENT_VALUES=()
  sf_environment_dir || return
  env_file=$REPLY/.env
  for name in $selected_names; do
    [[ ${parameters[$name]-} == *export* ]] || continue
    values[$name]=${(P)name}
  done
  if [[ -e $env_file || -L $env_file ]]; then
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

# Selected values keyed by name, for settings Shellfish reads itself.
typeset -gA SF_ENVIRONMENT_SETTINGS=()
sf_environment_settings() {
  local entry
  sf_environment_load "$1" || return
  SF_ENVIRONMENT_SETTINGS=()
  for entry in "${SF_ENVIRONMENT_VALUES[@]}"; do
    SF_ENVIRONMENT_SETTINGS[${entry%%=*}]=${entry#*=}
  done
}
