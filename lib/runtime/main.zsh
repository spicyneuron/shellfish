emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -g SF_RUNTIME_ERROR=''
typeset -g SF_PRESENTATION=''
typeset -g SF_RUNTIME_VERBOSE=0

sf_runtime_fail() {
  SF_RUNTIME_ERROR=$1
  return 1
}

sf_runtime_validation_error() {
  local output=$1 fallback=$2 detail=''
  [[ -z $output ]] || \
    detail=$(print -rn -- "$output" | LC_ALL=C tr -s '[:cntrl:]' ' ' | cut -c 1-1000)
  sf_runtime_fail "$fallback${detail:+: $detail}"
}

sf_runtime_read_jsonc() {
  awk '
    BEGIN { block = 0; string = 0; escaped = 0 }
    {
      for (i = 1; i <= length($0); i += 1) {
        character = substr($0, i, 1)
        next_character = substr($0, i + 1, 1)
        if (block) {
          if (character == "*" && next_character == "/") { block = 0; i += 1 }
          continue
        }
        if (string) {
          printf "%s", character
          if (escaped) escaped = 0
          else if (character == "\\") escaped = 1
          else if (character == "\"") string = 0
          continue
        }
        if (character == "\"") { string = 1; printf "%s", character }
        else if (character == "/" && next_character == "/") break
        else if (character == "/" && next_character == "*") { block = 1; i += 1; printf " " }
        else printf "%s", character
      }
      printf "\n"
    }
    END {
      if (block) { print "unterminated block comment" > "/dev/stderr"; exit 1 }
      if (string) { print "unterminated string" > "/dev/stderr"; exit 1 }
    }
  ' "$1" | jq -c .
}

sf_runtime_config_path() {
  local requested=${1-} candidate=''
  if [[ -n $requested ]]; then
    [[ $requested == /* ]] || requested="$PWD/$requested"
    candidate=$requested
  elif [[ -n ${XDG_CONFIG_HOME-} ]]; then
    candidate="$XDG_CONFIG_HOME/shellfish/shellfish.jsonc"
  elif [[ -n ${HOME-} ]]; then
    candidate="$HOME/.config/shellfish/shellfish.jsonc"
  fi
  if [[ -n $candidate ]]; then
    REPLY=${candidate:A}
  else
    REPLY=''
  fi
}

sf_runtime_read_config() {
  local requested_config=$1 config_path=$2 raw='{}'
  if [[ -n $config_path && ( -e $config_path || -L $config_path ) ]]; then
    [[ -f $config_path && -r $config_path ]] || {
      sf_runtime_fail "cannot read config: $config_path"
      return
    }
    raw=$(sf_runtime_read_jsonc "$config_path" 2>&1) || {
      sf_runtime_validation_error "$raw" "invalid config: $config_path"
      return
    }
  elif [[ -n $requested_config ]]; then
    sf_runtime_fail "cannot read config: $config_path"
    return
  fi
  REPLY=$raw
}

# --verbose lifts every preview limit. Presentation is resolved on each start
# rather than frozen, so this reaches stored sessions without touching a header.
sf_runtime_apply_verbose() {
  local updated
  (( SF_RUNTIME_VERBOSE )) || return 0
  updated=$(jq -c '.tui.preview_lines_reasoning = "full" |
    .tui.preview_lines_context = "full" |
    .tui.preview_lines_tool_call = "full" |
    .tui.preview_lines_tool_result = "full"' <<<"$SF_PRESENTATION") || {
    sf_runtime_fail 'cannot apply verbose preview limits'
    return
  }
  SF_PRESENTATION=$updated
}

sf_runtime_reference() {
  local reference=$1 base=$2 kind=$3 candidate
  if [[ $reference == /* ]]; then
    candidate=$reference
  elif [[ $reference == '~/'* ]]; then
    [[ -n ${HOME-} ]] || return 1
    candidate="$HOME/${reference#\~/}"
  elif [[ -n $base && ( -e $base/$kind/$reference || -L $base/$kind/$reference ) ]]; then
    candidate="$base/$kind/$reference"
  else
    candidate="$SF_ROOT/default/$kind/$reference"
  fi
  REPLY=${candidate:A}
}

sf_runtime_resolve() {
  local session_path=$1 requested_config=$2 requested_profile=$3
  local requested_model=$4 requested_request=$5 requested_backend=$6 runtime
  integer runtime_override=${7:-0}

  SF_RUNTIME_ERROR=''
  SF_PRESENTATION=''
  REPLY=''
  if [[ -n $session_path ]]; then
    if (( runtime_override )); then
      sf_runtime_fail 'runtime overrides cannot be used with an existing session'
      return 2
    fi
    sf_session_read_runtime "$session_path" || {
      sf_runtime_fail "$SF_SESSION_ERROR"
      return
    }
    runtime=$REPLY
    sf_runtime_restore_presentation "$requested_config" || return
    REPLY=$runtime
  else
    sf_runtime_resolve_from_config "$requested_config" "$requested_profile" \
      "$requested_model" "$requested_request" "$requested_backend" || return
  fi
}

sf_runtime_resolve_from_config() {
  local requested_config=$1 profile_override=$2 model_override=$3 request_override=$4
  local backend_override=${5-}
  local config_path config_dir='' raw='{}' defaults decoded prepared presentation
  local backend_name backend_reference backend_dir backend_base manifest tool_manifest command
  local context_window_command=''
  local reference resolved hook external_name final settings fence='' env_file=''
  local home=${HOME-} sandbox_read_paths=${_SHELLFISH_SANDBOX_READ_PATHS:-[]}
  local theme_marker=': shellfish:unknown-theme:'
  local -a fields tool_entries tool_paths tool_manifests sandbox_flags
  local -a system_entries component_entries resolved_args finalized
  integer tool_count system_count component_count index tool_index
  integer needs_fence=0 sandbox_enabled=1

  SF_RUNTIME_ERROR=''
  SF_PRESENTATION=''
  REPLY=''
  sf_runtime_config_path "$requested_config"
  config_path=$REPLY
  defaults=$(sf_runtime_read_jsonc "$SF_ROOT/default/shellfish.jsonc" 2>/dev/null) || {
    sf_runtime_fail 'invalid bundled config'
    return
  }
  sf_runtime_read_config "$requested_config" "$config_path" || return
  raw=$REPLY
  [[ -z $config_path ]] || config_dir=${config_path:h}
  [[ -z $config_path ]] || env_file=${config_dir:A}/.env
  [[ -z $home ]] || home=${home:A}

  external_name=${backend_override%/}
  external_name=${external_name:t}
  decoded=$(jq -L "$SF_ROOT" -jnre --argjson defaults "$defaults" \
    --argjson raw "$raw" --arg profile_override "$profile_override" \
    --arg model_override "$model_override" --argjson request_override "$request_override" \
    --arg backend_override "$backend_override" \
    --arg external_backend_name "$external_name" --arg home "$home" '
      include "libexec/config/runtime";
      def record: ., "\u0000";
      {defaults:$defaults,raw:$raw,profile_override:$profile_override,
       model_override:$model_override,request_override:$request_override,
       backend_override:$backend_override,
       external_backend_name:$external_backend_name,home:$home} |
      runtime_prepare as $prepared |
      ($prepared | tojson | record),
      ($prepared.presentation | tojson | record),
      ($prepared.profile.harness |
        if has("sandbox") then .sandbox else true end | tostring | record),
      ($prepared.backend_name | record),
      ($prepared.backend_reference | record),
      ($prepared.backend_external | tostring | record),
      ($prepared.tool_references | length | tostring | record),
      ($prepared.system_references | length | tostring | record),
      ($prepared.hook_component_references | length | tostring | record),
      ($prepared.tool_references[] | record),
      ($prepared.system_references[] | record),
      ($prepared.hook_component_references[] | .hook, "\u0000", .reference, "\u0000"),
      ("ok" | record)
  ' 2>&1) || {
    if [[ $decoded == *"$theme_marker"* ]]; then
      sf_runtime_fail "unknown theme: ${decoded#*"$theme_marker"}"
    else
      sf_runtime_validation_error "$decoded" "cannot prepare runtime"
    fi
    return
  }
  fields=( "${(@0)${decoded%$'\0'}}" )
  (( ${#fields} >= 10 )) && [[ $fields[-1] == ok ]] || {
    sf_runtime_fail 'cannot inspect prepared runtime'
    return
  }
  prepared=$fields[1]
  presentation=$fields[2]
  [[ $fields[3] == true ]] || sandbox_enabled=0
  fields=( "${(@)fields[4,-1]}" )
  backend_name=$fields[1]
  backend_reference=$fields[2]
  tool_count=$fields[4]
  system_count=$fields[5]
  component_count=$fields[6]
  index=7

  backend_base=$config_dir
  if [[ $fields[3] == true ]]; then
    [[ $backend_name =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
      sf_runtime_fail "invalid backend name: $backend_name"
      return
    }
    backend_base=$PWD
  fi
  if [[ $fields[3] == true && $backend_reference == */* &&
      $backend_reference != /* && $backend_reference != '~/'* ]]; then
    backend_dir=${backend_base:A}/$backend_reference
    backend_dir=${backend_dir:A}
  else
    sf_runtime_reference "$backend_reference" "$backend_base" backends || {
      sf_runtime_fail "cannot resolve backend: $backend_name"
      return
    }
    backend_dir=$REPLY
  fi
  [[ -d $backend_dir && -x $backend_dir/run && -f $backend_dir/backend.json && -r $backend_dir/backend.json ]] || {
    sf_runtime_fail "invalid backend: $backend_dir"
    return
  }
  command=$backend_dir/run
  [[ ! -f $backend_dir/context_window || ! -x $backend_dir/context_window ]] ||
    context_window_command=$backend_dir/context_window
  manifest=$(<"$backend_dir/backend.json")

  for (( tool_index = 0; tool_index < tool_count; tool_index++ )); do
    reference=$fields[index]
    (( index += 1 ))
    sf_runtime_reference "$reference" "$config_dir" tools || {
      sf_runtime_fail "cannot resolve tool directory: $reference"
      return
    }
    resolved=$REPLY
    [[ -d $resolved && -x $resolved/run && -f $resolved/tool.json && -r $resolved/tool.json ]] || {
      sf_runtime_fail "invalid tool directory: $reference"
      return
    }
    tool_paths+=( "$resolved" )
    tool_manifests+=( "$(<"$resolved/tool.json")" )
  done
  if (( tool_count )); then
    decoded=$(jq -jrn --args '
      ($ARGS.positional[] |
        ((try fromjson catch null) |
          if type == "object" then .sandbox == true else false end | tostring), "\u0000"),
      "ok", "\u0000"
    ' -- "${tool_manifests[@]}") || {
      sf_runtime_fail 'cannot inspect tool manifests'
      return
    }
    sandbox_flags=( "${(@0)${decoded%$'\0'}}" )
    (( ${#sandbox_flags} == tool_count + 1 )) && [[ $sandbox_flags[-1] == ok ]] || {
      sf_runtime_fail 'cannot inspect tool manifests'
      return
    }
    sandbox_flags[-1]=()
  fi
  for (( tool_index = 1; tool_index <= tool_count; tool_index++ )); do
    resolved=$tool_paths[tool_index]
    tool_manifest=$tool_manifests[tool_index]
    settings=''
    if [[ $sandbox_flags[tool_index] == true ]]; then
      settings="$resolved/fence.jsonc"
      [[ -f $settings && -r $settings ]] || {
        sf_runtime_fail "cannot read tool sandbox settings: $settings"
        return
      }
      (( sandbox_enabled )) && needs_fence=1
    fi
    tool_entries+=( "${${resolved%/}:t}" "$resolved/run" "$tool_manifest" "$settings" )
  done
  while (( ${#system_entries} < system_count )); do
    reference=$fields[index]
    (( index += 1 ))
    sf_runtime_reference "$reference" "$config_dir" system || {
      sf_runtime_fail "cannot resolve system component: $reference"
      return
    }
    resolved=$REPLY
    [[ -f $resolved && -r $resolved ]] || {
      sf_runtime_fail "cannot read system component: $reference"
      return
    }
    system_entries+=( "$resolved" )
  done
  while (( ${#component_entries} / 2 < component_count )); do
    hook=$fields[index]
    reference=$fields[index+1]
    (( index += 2 ))
    sf_runtime_reference "$reference" "$config_dir" "hooks/$hook" || {
      sf_runtime_fail "cannot resolve $hook hook script: $reference"
      return
    }
    resolved=$REPLY
    [[ -f $resolved && -x $resolved ]] || {
      sf_runtime_fail "$hook hook script is not executable: $reference"
      return
    }
    component_entries+=( "$hook" "$resolved" )
  done
  (( index == ${#fields} )) || {
    sf_runtime_fail 'cannot inspect prepared runtime'
    return
  }
  if (( needs_fence )); then
    [[ -n ${commands[fence]-} ]] || {
      sf_runtime_fail 'sandboxing requires fence'
      return
    }
    fence=${commands[fence]:A}
  fi

  (( ${#tool_entries} == tool_count * 4 && ${#system_entries} == system_count &&
    ${#component_entries} == component_count * 2 )) || {
    sf_runtime_fail 'cannot assemble resolved runtime references'
    return
  }
  resolved_args=( "${tool_entries[@]}" "${system_entries[@]}" "${component_entries[@]}" )
  final=$(jq -L "$SF_ROOT" -cnce --argjson prepared "$prepared" \
    --arg manifest "$manifest" --arg command "$command" \
    --arg context_window_command "$context_window_command" --arg fence "$fence" \
    --arg env_file "$env_file" \
    --argjson sandbox_read_paths "$sandbox_read_paths" \
    --argjson sandbox_write_paths "${_SHELLFISH_SANDBOX_WRITE_PATHS:-[]}" --args '
      include "libexec/config/runtime";
      include "lib/runtime/schema";
      {prepared:$prepared,manifest:$manifest,command:$command,
       context_window_command:$context_window_command,fence:$fence,
       env_file:$env_file,sandbox_read_paths:$sandbox_read_paths,
       sandbox_write_paths:$sandbox_write_paths,
       resolved:$ARGS.positional} |
      runtime_finalize as $result |
      ({type:"session",format_version:1,cwd:"/",created:"1970-01-01T00:00:00Z"} +
        $result.runtime) | select(canonical_session_header(1)) |
      $result.runtime
    ' "${resolved_args[@]}" 2>&1) || {
    sf_runtime_validation_error "$final" "cannot finalize runtime"
    return
  }
  finalized=( "${(@f)final}" )
  (( ${#finalized} == 1 )) || {
    sf_runtime_fail 'cannot finalize runtime'
    return
  }
  REPLY=$finalized[1]
  SF_PRESENTATION=$presentation
  sf_runtime_apply_verbose
}

sf_runtime_restore_presentation() {
  local requested_config=$1 config_path raw='{}' defaults output
  local invalid_marker=': shellfish:invalid-config'
  local theme_marker=': shellfish:unknown-theme:'
  SF_RUNTIME_ERROR=''
  SF_PRESENTATION=''
  sf_runtime_config_path "$requested_config"
  config_path=$REPLY
  defaults=$(sf_runtime_read_jsonc "$SF_ROOT/default/shellfish.jsonc" 2>/dev/null) || {
    sf_runtime_fail 'invalid bundled config'
    return
  }
  sf_runtime_read_config "$requested_config" "$config_path" || return
  raw=$REPLY
  output=$(jq -L "$SF_ROOT" -nce --argjson defaults "$defaults" \
    --argjson raw "$raw" '
      include "libexec/config/runtime";
      {defaults:$defaults,raw:$raw} | presentation_resolve
    ' 2>&1) || {
    if [[ $output == *"$theme_marker"* ]]; then
      sf_runtime_fail "unknown theme: ${output#*"$theme_marker"}"
    elif [[ $output == *"$invalid_marker" ]]; then
      sf_runtime_fail "invalid config: $config_path"
    else
      sf_runtime_validation_error "$output" \
        "invalid presentation config: ${config_path:-<defaults>}"
    fi
    return
  }
  SF_PRESENTATION=$output
  sf_runtime_apply_verbose
}

sf_runtime_resolve_api_key() {
  local runtime=$1 name line key value candidate env_file projected
  local -a credential_names
  local -A credentials
  SF_RUNTIME_ERROR=''
  REPLY=''
  reply=()
  local -a locator
  projected=$(jq -jr '
    .backend.api_key_env, "\u0000", .backend.env_file, "\u0000", "ok", "\u0000"
  ' <<<"$runtime" 2>/dev/null) || {
    sf_runtime_fail 'cannot read runtime credentials'
    return
  }
  locator=( "${(@0)${projected%$'\0'}}" )
  (( ${#locator} == 3 )) && [[ $locator[3] == ok ]] || {
    sf_runtime_fail 'cannot read runtime credentials'
    return
  }
  name=$locator[1]
  env_file=$locator[2]
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
      sf_runtime_fail "cannot read env file: $env_file"
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
        sf_runtime_fail "invalid env file line in $env_file"
        return
      }
      key=${line%%=*}
      key=${key%${key##*[![:space:]]}}
      key=${key#${key%%[![:space:]]*}}
      [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        sf_runtime_fail "invalid env name in $env_file: $key"
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

# Prints the resolved runtime with unfrozen theme palettes and TUI limits.
sf_runtime_report() {
  local runtime=$1
  jq -ne --argjson runtime "$runtime" --argjson presentation "$SF_PRESENTATION" '
    $runtime + {
      theme: {
        mode: $presentation.theme_mode,
        light: {name: $presentation.theme_light,
                palette: $presentation.themes[$presentation.theme_light]},
        dark: {name: $presentation.theme_dark,
               palette: $presentation.themes[$presentation.theme_dark]}
      },
      tui: $presentation.tui
    }
  '
}
