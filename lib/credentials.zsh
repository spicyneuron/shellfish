emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -g SF_CREDENTIALS_ERROR=''

sf_credentials_fail() {
  SF_CREDENTIALS_ERROR=$1
  return 1
}

sf_credentials_resolve() {
  local name=$1 env_file=$2 line key value candidate
  local -a credential_names
  local -A credentials
  SF_CREDENTIALS_ERROR=''
  REPLY=''
  reply=()
  credential_names=(SHELLFISH_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY)
  [[ -z $name || ${credential_names[(Ie)$name]} -gt 0 ]] || credential_names+=($name)
  for candidate in $credential_names; do
    if (( ${+parameters[$candidate]} )); then
      credentials[$candidate]=${(P)candidate}
      unset "$candidate"
    fi
  done
  if [[ -n $env_file && ( -e $env_file || -L $env_file ) ]]; then
    [[ -f $env_file && -r $env_file ]] || {
      sf_credentials_fail "cannot read env file: $env_file"
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
        sf_credentials_fail "invalid env file line in $env_file"
        return
      }
      key=${line%%=*}
      key=${key%${key##*[![:space:]]}}
      key=${key#${key%%[![:space:]]*}}
      [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        sf_credentials_fail "invalid env name in $env_file: $key"
        return
      }
      (( ${credential_names[(Ie)$key]} )) || continue
      (( ${+credentials[$key]} )) && continue
      value=${line#*=}
      value=${value#${value%%[![:space:]]*}}
      value=${value%${value##*[![:space:]]}}
      if (( ${#value} >= 2 )) && [[ $value == \"*\" || $value == \'*\' ]]; then
        value=${value[2,-2]}
      fi
      credentials[$key]=$value
    done <"$env_file"
  fi
  if (( ${+credentials[SHELLFISH_API_KEY]} )); then
    REPLY=${credentials[SHELLFISH_API_KEY]}
    reply=(SHELLFISH_API_KEY)
  elif [[ -n $name ]] && (( ${+credentials[$name]} )); then
    REPLY=${credentials[$name]}
    reply=("$name")
  fi
}
