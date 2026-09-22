emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_jsonc_read] )) || source "$SF_ROOT/lib/jsonc.zsh"
[[ -n ${SF_SHARE-} ]] || typeset -g SF_SHARE=$SF_ROOT/share

typeset -g SF_RUNTIME_ERROR=''
typeset -g SF_RUNTIME_SANDBOX_GRANTS='{"sandbox_read_paths":[],"sandbox_write_paths":[]}'

sf_runtime_fail() {
  SF_RUNTIME_ERROR=$1
  return 1
}

# jq's own "jq: " prefix says nothing the fallback message has not already said.
sf_runtime_validation_error() {
  local output=$1 fallback=$2 detail=''
  [[ -z $output ]] || \
    detail=$(print -rn -- "$output" | LC_ALL=C tr -s '[:cntrl:]' ' ' | cut -c 1-1000)
  detail=${detail#jq: }
  sf_runtime_fail "$fallback${detail:+: $detail}"
}

sf_runtime_read_manifest() {
  local directory=$1 mode=$2 json="$1/manifest.json" jsonc="$1/manifest.jsonc"
  local manifest_path content
  if [[ ( -e $json || -L $json ) && ( -e $jsonc || -L $jsonc ) ]]; then
    sf_runtime_fail "multiple component manifests: $directory"
    return
  elif [[ -e $jsonc || -L $jsonc ]]; then
    manifest_path=$jsonc
  elif [[ -e $json || -L $json ]]; then
    manifest_path=$json
  elif [[ $mode == optional ]]; then
    REPLY='{"environment":[]}'
    return 0
  else
    sf_runtime_fail "missing component manifest: $directory"
    return
  fi
  [[ -f $manifest_path && -r $manifest_path ]] || {
    sf_runtime_fail "cannot read component manifest: $manifest_path"
    return
  }
  content=$(sf_jsonc_read "$manifest_path" 2>&1) || {
    sf_runtime_validation_error "$content" "invalid component manifest: $manifest_path"
    return
  }
  REPLY=$content
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
    raw=$(sf_jsonc_read "$config_path" 2>&1) || {
      sf_runtime_validation_error "$raw" "invalid config: $config_path"
      return
    }
  elif [[ -n $requested_config ]]; then
    sf_runtime_fail "cannot read config: $config_path"
    return
  fi
  REPLY=$raw
}

sf_runtime_load_config() {
  local requested_config=$1 config_path defaults raw
  sf_runtime_config_path "$requested_config"
  config_path=$REPLY
  defaults=$(sf_jsonc_read "$SF_SHARE/default/shellfish.jsonc" 2>/dev/null) || {
    sf_runtime_fail 'invalid bundled config'
    return
  }
  sf_runtime_read_config "$requested_config" "$config_path" || return
  raw=$REPLY
  reply=( config_path "$config_path" defaults "$defaults" raw "$raw" )
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
    candidate="$SF_SHARE/default/$kind/$reference"
  fi
  REPLY=${candidate:A}
}

sf_runtime_resolve_from_config() {
  local requested_config=$1 profile_override=$2 model_override=$3 request_override=$4
  local backend_override=${5-}
  local config_path config_dir='' raw defaults prepared external
  local backend_name backend_reference backend_dir backend_base manifest command
  local context_window_command=''
  local reference resolved hook hook_manifest hook_match external_name final settings fence='' env_file=''
  local home=${HOME-}
  local -A decoded
  local -a tool_entries system_entries component_entries
  local -A loaded
  local -a tool_references system_references component_references
  integer settings_readable

  SF_RUNTIME_ERROR=''
  REPLY=''
  sf_runtime_load_config "$requested_config" || return
  loaded=( "${reply[@]}" )
  config_path=$loaded[config_path]
  defaults=$loaded[defaults]
  raw=$loaded[raw]
  [[ -z $config_path ]] || config_dir=${config_path:h}
  [[ -z $config_path ]] || env_file=${config_dir:A}/.env
  [[ -z $home ]] || home=${home:A}

  external_name=${backend_override%/}
  external_name=${external_name:t}
  # A reference carries no control characters, so newlines delimit each list.
  sf_jq_fields -rn --argjson defaults "$defaults" \
    --argjson raw "$raw" --arg profile_override "$profile_override" \
    --arg model_override "$model_override" --argjson request_override "$request_override" \
    --arg backend_override "$backend_override" \
    --arg external_backend_name "$external_name" --arg home "$home" '
      include "lib/fields";
      include "lib/runtime";
      {defaults:$defaults,raw:$raw,profile_override:$profile_override,
       model_override:$model_override,request_override:$request_override,
       backend_override:$backend_override,
       external_backend_name:$external_backend_name,home:$home} |
      runtime_prepare as $prepared |
      entry("prepared"; $prepared | tojson),
      entry("backend_name"; $prepared.backend_name),
      entry("backend_reference"; $prepared.backend_reference),
      entry("backend_external"; $prepared.backend_external | tostring),
      entry("tools"; $prepared.tool_references | join("\n")),
      entry("system"; $prepared.system_references | join("\n")),
      entry("hooks";
        [$prepared.hook_component_references[] | .hook + " " + .reference] | join("\n")),
      ("ok" | field)
  ' || {
    sf_runtime_validation_error "$REPLY" "cannot prepare runtime"
    return
  }
  decoded=( "${reply[@]}" )
  prepared=$decoded[prepared]
  backend_name=$decoded[backend_name]
  backend_reference=$decoded[backend_reference]
  external=$decoded[backend_external]
  tool_references=( ${(f)decoded[tools]} )
  system_references=( ${(f)decoded[system]} )
  component_references=( ${(f)decoded[hooks]} )

  backend_base=$config_dir
  if [[ $external == true ]]; then
    [[ $backend_name =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
      sf_runtime_fail "invalid backend name: $backend_name"
      return
    }
    backend_base=$PWD
  fi
  if [[ $external == true && $backend_reference == */* &&
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
  [[ -d $backend_dir && -x $backend_dir/run ]] || {
    sf_runtime_fail "invalid backend: $backend_dir"
    return
  }
  sf_runtime_read_manifest "$backend_dir" required || return
  manifest=$REPLY
  command=$backend_dir/run
  [[ ! -f $backend_dir/context_window || ! -x $backend_dir/context_window ]] ||
    context_window_command=$backend_dir/context_window

  for reference in "${tool_references[@]}"; do
    sf_runtime_reference "$reference" "$config_dir" tools || {
      sf_runtime_fail "cannot resolve tool directory: $reference"
      return
    }
    resolved=$REPLY
    [[ -d $resolved && -x $resolved/run ]] || {
      sf_runtime_fail "invalid tool directory: $reference"
      return
    }
    sf_runtime_read_manifest "$resolved" required || return
    settings="$resolved/fence.jsonc"
    settings_readable=0
    [[ ! -f $settings || ! -r $settings ]] || settings_readable=1
    tool_entries+=( "${${resolved%/}:t}" "$resolved/run" "$REPLY" \
      "$settings" "$settings_readable" )
  done
  for reference in "${system_references[@]}"; do
    sf_runtime_reference "$reference" "$config_dir" system || {
      sf_runtime_fail "cannot resolve system component: $reference"
      return
    }
    system_entries+=( "$REPLY" )
  done
  for reference in "${component_references[@]}"; do
    hook=${reference%% *}
    reference=${reference#* }
    sf_runtime_reference "$reference" "$config_dir" "hooks/$hook" || {
      sf_runtime_fail "cannot resolve $hook hook script: $reference"
      return
    }
    resolved=$REPLY
    [[ -d $resolved && -x $resolved/run ]] || {
      sf_runtime_fail "invalid $hook hook: $reference"
      return
    }
    sf_runtime_read_manifest "$resolved" optional || return
    hook_manifest=$REPLY
    hook_match=''
    [[ ! -f $resolved/match || ! -x $resolved/match ]] || hook_match=$resolved/match
    component_entries+=( "$hook" "$resolved/run" "$hook_manifest" "$hook_match" )
  done
  [[ -z ${commands[fence]-} ]] || fence=${commands[fence]:A}

  # The two counts split the resolved entries into their three lists.
  final=$(sf_jq -cnce --argjson prepared "$prepared" \
    --arg manifest "$manifest" --arg command "$command" \
    --arg context_window_command "$context_window_command" --arg fence "$fence" \
    --arg env_file "$env_file" --argjson tool_words "${#tool_entries}" \
    --argjson component_words "${#component_entries}" \
    --argjson grants "$SF_RUNTIME_SANDBOX_GRANTS" --args '
      include "lib/runtime";
      ({prepared:$prepared,manifest:$manifest,command:$command,
        context_window_command:$context_window_command,fence:$fence,
        env_file:$env_file,
        resolved:($ARGS.positional |
          {tools:.[:$tool_words],
           components:.[$tool_words:$tool_words + $component_words],
           system:.[$tool_words + $component_words:]})} + $grants) |
      runtime_finalize
    ' -- "${tool_entries[@]}" "${component_entries[@]}" "${system_entries[@]}" 2>&1) || {
    sf_runtime_validation_error "$final" "cannot finalize runtime"
    return
  }
  REPLY=$final
}

# Parse the options that select a runtime, then resolve it. Callers that own
# their own flags pass only the ones listed in lib/options.zsh.
sf_runtime_resolve_args() {
  local config='' profile='' model='' backend=''
  local request='{}' flag grant resolved
  local -a read_paths=() write_paths=()
  integer detect=0

  SF_RUNTIME_ERROR=''
  while (( $# )); do
    case $1 in
      --config)
        [[ -n $2 && $2 != - ]] ||
          sf_runtime_fail '--config requires a nonempty file path other than -' || return 2
        config=$2
        shift 2
        ;;
      -p|--profile)
        [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
          sf_runtime_fail '--profile must match [A-Za-z0-9][A-Za-z0-9_-]*' || return 2
        profile=$2
        shift 2
        ;;
      -m|--model)
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] ||
          sf_runtime_fail '--model requires a nonempty value without control characters' || return 2
        model=$2
        shift 2
        ;;
      -b|--backend)
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] ||
          sf_runtime_fail '--backend requires a nonempty value without control characters' || return 2
        backend=$2
        shift 2
        ;;
      --request)
        request=$(jq -ce 'select(type == "object")' <<<"$2" 2>/dev/null) ||
          sf_runtime_fail '--request requires a JSON object' || return 2
        shift 2
        ;;
      --sandbox-read|--sandbox-write)
        flag=$1
        [[ -n $2 ]] || sf_runtime_fail "$flag requires a nonempty path" || return 2
        grant=$2
        if [[ $grant == '~/'* ]]; then
          [[ -n ${HOME-} ]] || sf_runtime_fail "$flag cannot expand ~ without HOME" || return 2
          grant="$HOME/${grant#\~/}"
        elif [[ $grant != /* ]]; then
          grant="$PWD/$grant"
        fi
        resolved=${grant:A}
        [[ -e $resolved ]] || sf_runtime_fail "$flag path does not exist: $2" || return 2
        if [[ $flag == --sandbox-read ]]; then
          read_paths+=( "$resolved" )
        else
          write_paths+=( "$resolved" )
        fi
        shift 2
        ;;
      --sandbox-auto)
        detect=1
        shift
        ;;
      *)
        sf_runtime_fail "unknown argument: $1"
        return 2
        ;;
    esac
  done

  if (( detect || ${#read_paths} || ${#write_paths} )); then
    local detected='{"sandbox_read_paths":[],"sandbox_write_paths":[]}'
    if (( detect )); then
      (( $+functions[sf_sandbox_detect] )) || source "$SF_ROOT/lib/sandbox.zsh"
      detected=$(sf_sandbox_detect) || sf_runtime_fail 'cannot detect sandbox paths' || return
    fi
    # The read count splits explicit read and write path arguments.
    SF_RUNTIME_SANDBOX_GRANTS=$(jq -cn --argjson detected "$detected" \
      --argjson reads "${#read_paths}" --args '
        {sandbox_read_paths: ($ARGS.positional[:$reads] + $detected.sandbox_read_paths),
         sandbox_write_paths: ($ARGS.positional[$reads:] + $detected.sandbox_write_paths)}
      ' -- "${read_paths[@]}" "${write_paths[@]}") ||
      sf_runtime_fail 'cannot prepare sandbox grants' || return
  fi

  sf_runtime_resolve_from_config "$config" "$profile" "$model" "$request" "$backend"
}
