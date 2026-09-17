emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -g SF_ENVIRONMENT_ERROR=''
typeset -ga SF_ENVIRONMENT_NAMES=()
typeset -ga SF_ENVIRONMENT_VALUES=()
typeset -g SF_ENVIRONMENT_RUNTIME=''
typeset -g SF_ENVIRONMENT_FILE=''

sf_environment_fail() {
  SF_ENVIRONMENT_ERROR=$1
  return 1
}

sf_environment_project() {
  local runtime=$1 projection
  local -a fields
  [[ $runtime != $SF_ENVIRONMENT_RUNTIME ]] || return 0
  SF_ENVIRONMENT_RUNTIME=''
  SF_ENVIRONMENT_NAMES=()
  SF_ENVIRONMENT_FILE=''
  projection=$(sf_jq -L "$SF_ROOT" -jrn --argjson runtime "$runtime" '
      include "lib/runtime";
      def field: ., "\u0000";
      ($runtime.backend.env_file | field),
      ([$runtime.backend.environment[]?,
        $runtime.harness.tools[].manifest.environment[]?,
        (hook_names[] as $hook | $runtime.harness[$hook][]?.environment[]?)] |
       unique | join(" ") | field),
      ("ok" | field)
    ' 2>/dev/null) || return 1
  fields=( "${(@0)${projection%$'\0'}}" )
  (( ${#fields} == 3 )) && [[ $fields[3] == ok ]] || return 1
  SF_ENVIRONMENT_FILE=$fields[1]
  SF_ENVIRONMENT_NAMES=( ${=fields[2]} )
  SF_ENVIRONMENT_RUNTIME=$runtime
}

# Canonical environment names cannot contain spaces.
sf_environment_prepare() {
  local runtime=$1 selected=$2 name
  local -a selected_names

  SF_ENVIRONMENT_ERROR=''
  sf_environment_project "$runtime" || {
    sf_environment_fail 'cannot inspect component environment'
    return
  }
  selected_names=( ${=selected} )
  for name in $selected_names; do
    (( ${SF_ENVIRONMENT_NAMES[(Ie)$name]} )) || {
      sf_environment_fail 'cannot inspect component environment'
      return
    }
  done
  sf_environment_load "$SF_ENVIRONMENT_FILE" "$selected"
}

sf_environment_load() {
  local env_file=$1 selected=$2 line key value name
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
    [[ -n $env_file && ( -e $env_file || -L $env_file ) ]]; then
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
        sf_environment_fail "invalid env file line in $SF_ENVIRONMENT_FILE"
        return
      }
      key=${line%%=*}
      key=${key%${key##*[![:space:]]}}
      key=${key#${key%%[![:space:]]*}}
      [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        sf_environment_fail "invalid env name in $SF_ENVIRONMENT_FILE: $key"
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
