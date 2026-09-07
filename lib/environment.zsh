emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -g SF_ENVIRONMENT_ERROR=''
typeset -ga SF_ENVIRONMENT_NAMES=()
typeset -ga SF_ENVIRONMENT_VALUES=()

sf_environment_fail() {
  SF_ENVIRONMENT_ERROR=$1
  return 1
}

sf_environment_prepare() {
  local runtime=$1 selected=$2 env_file projection line key value name
  local -a fields selected_names
  local -A values
  integer all_count selected_count index

  SF_ENVIRONMENT_ERROR=''
  SF_ENVIRONMENT_NAMES=()
  SF_ENVIRONMENT_VALUES=()
  projection=$(sf_jq -L "$SF_ROOT" -jrn --argjson runtime "$runtime" \
    --argjson selected "$selected" '
      include "lib/runtime/schema";
      def field: ., "\u0000";
      [$runtime.backend.environment[]?,
       $runtime.harness.tools[].manifest.environment[]?,
       (hook_names[] as $hook | $runtime.harness[$hook][]?.environment[]?)] |
      unique as $all |
      select($selected | component_environment) |
      select($selected - $all | length == 0) |
      ($runtime.backend.env_file | field),
      ($all | length | tostring | field),
      ($selected | length | tostring | field),
      ($all[] | field), ($selected[] | field), ("ok" | field)
    ' 2>/dev/null) || {
    sf_environment_fail 'cannot inspect component environment'
    return
  }
  fields=( "${(@0)${projection%$'\0'}}" )
  (( ${#fields} >= 4 )) && [[ $fields[2] == <-> && $fields[3] == <-> && $fields[-1] == ok ]] || {
    sf_environment_fail 'cannot inspect component environment'
    return
  }
  env_file=$fields[1]
  all_count=$fields[2]
  selected_count=$fields[3]
  (( ${#fields} == all_count + selected_count + 4 )) || {
    sf_environment_fail 'cannot inspect component environment'
    return
  }
  SF_ENVIRONMENT_NAMES=( "${(@)fields[4,$(( all_count + 3 ))]}" )
  index=$(( all_count + 4 ))
  selected_names=( "${(@)fields[index,$(( index + selected_count - 1 ))]}" )

  for name in $selected_names; do
    if [[ ${parameters[$name]-} == *export* ]]; then
      values[$name]=${(P)name}
    fi
  done
  if (( selected_count )) && [[ -n $env_file && ( -e $env_file || -L $env_file ) ]]; then
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
