emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_jsonc_read] )) || source "$SF_ROOT/lib/jsonc.zsh"
(( $+functions[sf_cli_diagnostic] )) || source "$SF_ROOT/lib/cli.zsh"
[[ -n ${SF_SHARE-} ]] ||
  typeset -g SF_SHARE=$SF_ROOT/share

typeset -g SF_RUNTIME_ERROR=''
typeset -g SF_RUNTIME_SANDBOX_GRANTS='{"sandbox_read_paths":[],"sandbox_write_paths":[]}'

sf_runtime_fail() {
  SF_RUNTIME_ERROR=$1
  return 1
}

sf_runtime_validation_error() {
  local output=$1 fallback=$2
  sf_cli_diagnostic "$output"
  sf_runtime_fail "$fallback${REPLY:+: $REPLY}"
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

sf_runtime_config_dir() {
  local base=${XDG_CONFIG_HOME:-${HOME:+$HOME/.config}}
  [[ -n $base ]] || sf_runtime_fail 'HOME or XDG_CONFIG_HOME is required' || return
  REPLY=${base:A}/shellfish
}

sf_runtime_read_profiles() {
  local config_dir=$1 file detail profiles
  local -a files=( "$SF_SHARE/default/profiles"/*.jsonc(N-.)
    "$config_dir/profiles"/*.jsonc(N-.) )
  profiles=$(sf_jsonc_read_keyed "${files[@]}" 2>&1) || {
    # One bad file spoils the batch, so name it.
    for file in "${files[@]}"; do
      detail=$(sf_jsonc_read "$file" 2>&1) ||
        sf_runtime_validation_error "$detail" "invalid profile: $file" || return
    done
    sf_runtime_fail 'cannot read profiles'
    return
  }
  REPLY=$profiles
}

sf_runtime_reference() {
  local reference=$1 base=$2 kind=$3 candidate
  if [[ $reference == /* ]]; then
    candidate=$reference
  elif [[ $reference == '~/'* ]]; then
    [[ -n ${HOME-} ]] || return 1
    candidate="$HOME/${reference#\~/}"
  elif [[ -e $base/$kind/$reference || -L $base/$kind/$reference ]]; then
    candidate="$base/$kind/$reference"
  else
    candidate="$SF_SHARE/default/$kind/$reference"
  fi
  REPLY=${candidate:A}
}

# Walk the selected profile's references into the resolution table: one uniform
# record of table key, resolved path, optional-script flag, and manifest.
sf_runtime_resolve_profile() {
  local profile_names=$1 model_override=$2 request_override=$3 backend_override=$4
  local config_dir profiles profile kind reference subdirectory key resolved final
  local fence='' home=${HOME-}
  local -A decoded
  local -a entries=() references=()
  integer flag

  SF_RUNTIME_ERROR=''
  REPLY=''
  sf_runtime_config_dir || return
  config_dir=$REPLY
  sf_runtime_read_profiles "$config_dir" || return
  profiles=$REPLY
  [[ -z $home ]] || home=${home:A}

  # A reference carries no control characters, so newlines delimit the list and
  # a space separates each kind from its reference.
  sf_jq_fields -rn --argjson files "$profiles" --arg names "$profile_names" \
    --arg bundled "$SF_SHARE/default/profiles" \
    --arg model "$model_override" --argjson request "$request_override" \
    --arg backend "$backend_override" --arg home "$home" '
      include "lib/fields";
      include "lib/runtime";
      profile_select($files | profile_map($bundled);
        (($names | select(length > 0) | split("\n")) // ["default"]);
        $model; $request; $backend; $home) as $profile |
      entry("profile"; $profile | tojson),
      entry("references";
        [["backend", $profile.backend.adapter],
         (($profile.harness.tools // [])[] | ["tools", .]),
         (($profile.system // [])[] | ["system", .]),
         (hook_names[] as $hook | ($profile.harness[$hook] // [])[] |
           ["hooks/" + $hook, .])] |
        map(join(" ")) | join("\n")),
      ("ok" | field)
  ' || {
    sf_runtime_validation_error "$REPLY" 'cannot select profile'
    return
  }
  decoded=( "${reply[@]}" )
  profile=$decoded[profile]
  references=( ${(f)decoded[references]} )

  for reference in "${references[@]}"; do
    kind=${reference%% *}
    reference=${reference#* }
    # There is exactly one backend, so it needs no reference in its key.
    subdirectory=$kind
    key="$kind"$'\t'"$reference"
    [[ $kind != backend ]] || { subdirectory=backends; key=backend; }
    sf_runtime_reference "$reference" "$config_dir" "$subdirectory" || {
      sf_runtime_fail "cannot resolve $kind reference: $reference"
      return
    }
    resolved=$REPLY
    flag=0
    if [[ $kind == system ]]; then
      entries+=( "$key" "$resolved" 0 '{}' )
      continue
    fi
    [[ -d $resolved && -x $resolved/run ]] || {
      sf_runtime_fail "invalid $kind reference: $reference"
      return
    }
    case $kind in
      backend)
        sf_runtime_read_manifest "$resolved" required || return
        [[ ! -f $resolved/context_window || ! -x $resolved/context_window ]] || flag=1
        ;;
      tools)
        sf_runtime_read_manifest "$resolved" required || return
        [[ ! -f $resolved/fence.jsonc || ! -r $resolved/fence.jsonc ]] || flag=1
        ;;
      *)
        sf_runtime_read_manifest "$resolved" optional || return
        [[ ! -f $resolved/match || ! -x $resolved/match ]] || flag=1
        ;;
    esac
    entries+=( "$key" "$resolved" "$flag" "$REPLY" )
  done
  [[ -z ${commands[fence]-} ]] || fence=${commands[fence]:A}

  final=$(sf_jq -cnce --argjson profile "$profile" --arg config_dir "$config_dir" \
    --arg fence "$fence" --argjson grants "$SF_RUNTIME_SANDBOX_GRANTS" --args '
      include "lib/runtime";
      runtime_finalize($profile; resolution_table($ARGS.positional);
        $config_dir; $fence; $grants)
    ' -- "${entries[@]}" 2>&1) || {
    sf_runtime_validation_error "$final" 'cannot finalize runtime'
    return
  }
  REPLY=$final
}

# Parse the options that select a runtime, then resolve it. Callers that own
# their own flags pass only the ones listed in lib/options.zsh.
sf_runtime_resolve_args() {
  local model='' backend=''
  local request='{}' flag grant resolved
  local -a profiles=() read_paths=() write_paths=()
  integer detect=0

  SF_RUNTIME_ERROR=''
  while (( $# )); do
    case $1 in
      -p|--profile)
        [[ $2 =~ ^@?[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
          sf_runtime_fail '--profile must match @?[A-Za-z0-9][A-Za-z0-9_-]*' || return 2
        profiles+=( "$2" )
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

  sf_runtime_resolve_profile "${(pj:\n:)profiles}" "$model" "$request" "$backend"
}
