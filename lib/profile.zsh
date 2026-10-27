emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_jsonc_read] )) || source "$SF_ROOT/lib/jsonc.zsh"
(( $+functions[sf_cli_diagnostic] )) || source "$SF_ROOT/lib/cli.zsh"
(( $+functions[sf_environment_dir] )) || source "$SF_ROOT/lib/environment.zsh"

typeset -g SF_PROFILE_ERROR=''

sf_profile_fail() {
  SF_PROFILE_ERROR=$1
  return 1
}

sf_profile_validation_error() {
  local output=$1 fallback=$2
  sf_cli_diagnostic "$output"
  sf_profile_fail "$fallback${REPLY:+: $REPLY}"
}

# JSONC files keyed by path. One bad file spoils the batch, so name it.
sf_profile_read_files() {
  local label=$1 file detail content
  shift
  content=$(sf_jsonc_read_keyed "$@" 2>&1) || {
    for file; do
      detail=$(sf_jsonc_read "$file" 2>&1) ||
        sf_profile_validation_error "$detail" "$label: $file" || return
    done
    sf_profile_fail "$label"
    return
  }
  REPLY=$content
}

sf_profile_manifest() {
  local directory=$1
  local -a files=( "$directory"/manifest.(json|jsonc)(N) )
  (( ${#files} <= 1 )) || sf_profile_fail "multiple component manifests: $directory" || return
  REPLY=${files[1]-}
  [[ -z $REPLY || ( -f $REPLY && -r $REPLY ) ]] ||
    sf_profile_fail "cannot read component manifest: $directory"
}

# The parsed manifest of a component folder.
sf_profile_read_manifest() {
  sf_profile_manifest "$1" || return
  local file=$REPLY
  [[ -n $file ]] || { REPLY='{}'; return 0; }
  REPLY=$(sf_jsonc_read "$file" 2>&1) ||
    sf_profile_validation_error "$REPLY" "invalid component manifest: $file"
}

sf_profile_reference() {
  local reference=$1 kind=$2 config_dir=$3 folder candidate=''
  if [[ $reference != /* && $reference != '~/'* &&
      ( /$reference/ == */../* || /$reference/ == */./* ) ]]; then
    return 1
  fi
  case $reference in
    /*) candidate=$reference ;;
    '~/'*) [[ -z ${HOME-} ]] || candidate="$HOME/${reference#\~/}" ;;
    @$kind/*) candidate="$SF_SHARE/${reference#@}" ;;
    @*) return 1 ;;
    *)
      for folder in "$config_dir" "$SF_SHARE"; do
        [[ -e $folder/$kind/$reference || -L $folder/$kind/$reference ]] || continue
        candidate="$folder/$kind/$reference"
        break
      done
      ;;
  esac
  [[ -n $candidate ]] || return 1
  REPLY=${candidate:A}
}

# The tools of an expanded profile, read live from their manifests.
# The tools of an expanded profile, read live from their manifests.
sf_profile_tools() {
  local profile=$1 directory projection
  local -a directories files=()
  projection=$(jq -r '.tools[]' <<<"$profile") ||
    sf_profile_fail 'cannot read profile tools' || return
  directories=( ${(f)projection} )
  for directory in "${directories[@]}"; do
    [[ -d $directory && -x $directory/run ]] ||
      sf_profile_fail "invalid tools reference: $directory" || return
    sf_profile_manifest "$directory" || return
    [[ -z $REPLY ]] || files+=( "$REPLY" )
  done
  REPLY='{}'
  (( ! ${#files} )) || sf_profile_read_files 'invalid component manifest' "${files[@]}" || return
  projection=$(sf_jq -cn --argjson manifests "$REPLY" '
    include "lib/profile";
    ($manifests | with_entries(.key |= sub("/[^/]*$"; ""))) as $manifests |
    [$ARGS.positional[] as $directory |
      (($manifests[$directory] // {}) | select(tool_manifest) //
        error("invalid tool manifest: " + $directory)) as $manifest |
      {name:($directory | split("/") | last), command:($directory + "/run"),
       manifest:$manifest}]
  ' --args "${directories[@]}" 2>&1) || {
    sf_profile_validation_error "$projection" 'cannot read tools'
    return
  }
  REPLY=$projection
}

# A named profile or model file: yours first, then bundled. "@NAME" is bundled.
sf_profile_named() {
  local kind=$1 name=$2 config_dir=$3
  [[ $name =~ '^@?[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$' ]] ||
    sf_profile_fail "invalid $kind name: $name" || return
  if [[ $name == @* ]]; then
    REPLY="$SF_SHARE/${kind}s/${name#@}.jsonc"
  else
    REPLY="$config_dir/${kind}s/$name.jsonc"
    [[ -e $REPLY || -L $REPLY ]] || REPLY="$SF_SHARE/${kind}s/$name.jsonc"
  fi
  [[ -e $REPLY || -L $REPLY ]] || sf_profile_fail "unknown $kind: $name"
}

# Resolve profile NAME with extra model names merged after its own, a request
# override applied last, and sandbox GRANTS from flags. The sandbox defaults
# come from SHELLFISH_SANDBOX and colon-separated SHELLFISH_SANDBOX_READ and
# SHELLFISH_SANDBOX_WRITE. REPLY is the profile with absolute paths.
sf_profile_resolve() {
  local name=${1:-default} extra_models=$2 request=${3:-'{}'} grants=${4:-'{}'}
  local config_dir profile listed models model reference kind resolved selected final
  local backend_manifest='{}' hook_manifests='{}'
  local -a model_names model_files references resolutions=() hook_files=()
  local -A decoded

  SF_PROFILE_ERROR=''
  REPLY=''
  sf_environment_dir || sf_profile_fail "$SF_ENVIRONMENT_ERROR" || return
  config_dir=$REPLY
  sf_profile_named profile "$name" "$config_dir" || return
  profile=$(sf_jsonc_read "$REPLY" 2>&1) ||
    sf_profile_validation_error "$profile" "invalid profile: $REPLY" || return
  listed=$(sf_jq -rn --argjson profile "$profile" --arg name "$name" '
    include "lib/profile";
    $profile | config_profile(["profile " + $name]) | .model[]?
  ' 2>&1) || { sf_profile_validation_error "$listed" 'invalid configuration'; return; }
  model_names=( ${(f)listed} ${(f)extra_models} )
  (( ${#model_names} )) || sf_profile_fail "profile selects no model: $name" || return
  for model in "${model_names[@]}"; do
    sf_profile_named model "$model" "$config_dir" || return
    model_files+=( "$REPLY" )
  done
  sf_profile_read_files 'invalid model' "${(u)model_files[@]}" || return
  models=$REPLY
  sf_environment_settings 'SHELLFISH_SANDBOX SHELLFISH_SANDBOX_READ SHELLFISH_SANDBOX_WRITE' ||
    sf_profile_fail "$SF_ENVIRONMENT_ERROR" || return
  [[ ${SF_ENVIRONMENT_SETTINGS[SHELLFISH_SANDBOX]:-1} == [01] ]] ||
    sf_profile_fail 'SHELLFISH_SANDBOX must be 0 or 1' || return

  sf_jq_fields -rn --argjson profile "$profile" --argjson models "$models" \
    --argjson request "$request" --args '
      include "lib/fields";
      include "lib/profile";
      [$ARGS.positional as $files | range(0; $files | length; 2) as $at |
        $models[$files[$at]] | config_model(["model " + $files[$at + 1]])] as $models |
      {model:model_merge($models; $request), system:($profile.system // []),
       tools:($profile.tools // []), hooks:($profile.hooks // [])} |
      if (.tools | length) == (.tools | unique | length) then .
      else error("profile tools must be unique: " + (.tools | join(", "))) end |
      entry("profile"; tojson),
      entry("references"; [["backends", .model.adapter], (.system[] | ["system", .]),
        (.tools[] | ["tools", .]), (.hooks[] | ["hooks", .])] | unique |
        map(join(" ")) | join("\n")),
      ("ok" | field)
  ' "${model_files[@]:^model_names}" || {
    sf_profile_validation_error "$REPLY" 'invalid configuration'
    return
  }
  decoded=( "${reply[@]}" )
  selected=$decoded[profile]
  references=( ${(f)decoded[references]} )

  # A reference carries no control characters, so newlines delimit the list.
  for reference in "${references[@]}"; do
    kind=${reference%% *}
    sf_profile_reference "${reference#* }" "$kind" "$config_dir" ||
      sf_profile_fail "cannot resolve $kind reference: ${reference#* }" || return
    resolved=$REPLY
    case $kind in
      system) [[ -f $resolved && -r $resolved ]] ;;
      *) [[ -d $resolved && -x $resolved/run ]] ;;
    esac || sf_profile_fail "invalid $kind reference: ${reference#* }" || return
    case $kind in
      backends)
        sf_profile_read_manifest "$resolved" || return
        backend_manifest=$REPLY
        ;;
      hooks)
        sf_profile_manifest "$resolved" || return
        [[ -n $REPLY ]] || sf_profile_fail "hook manifest must declare \"on\": ${reference#* }" || return
        hook_files+=( "$REPLY" )
        ;;
    esac
    resolutions+=( "$reference" "$resolved" )
  done
  (( ! ${#hook_files} )) ||
    sf_profile_read_files 'invalid component manifest' "${hook_files[@]}" || return
  (( ! ${#hook_files} )) || hook_manifests=$REPLY

  final=$(sf_jq -nce --argjson profile "$selected" --argjson manifest "$backend_manifest" \
    --argjson hooks "$hook_manifests" --argjson grants "$grants" \
    --arg sandbox "${SF_ENVIRONMENT_SETTINGS[SHELLFISH_SANDBOX]:-1}" \
    --arg read "${SF_ENVIRONMENT_SETTINGS[SHELLFISH_SANDBOX_READ]-}" \
    --arg write "${SF_ENVIRONMENT_SETTINGS[SHELLFISH_SANDBOX_WRITE]-}" \
    --arg share "$SF_SHARE" --arg home "${HOME:+${HOME:A}}" '
      include "lib/profile";
      def paths: split(":") | map(select(. != ""));
      ($ARGS.positional | [range(0; length; 2) as $at | {key:.[$at], value:.[$at + 1]}] |
        from_entries) as $paths |
      ($hooks | with_entries(.key |= sub("/[^/]*$"; ""))) as $hooks |
      ($manifest | select(type == "object" and (keys - ["endpoint"]) == [] and
        ((has("endpoint") | not) or (.endpoint | endpoint))) //
        error("invalid backend manifest")) as $manifest |
      $profile |
      .model.adapter = $paths["backends " + .model.adapter] |
      .model.endpoint //= $manifest.endpoint |
      if .model.endpoint == null then error("backend endpoint is required") else . end |
      .system |= map($paths["system " + .]) |
      .tools |= map($paths["tools " + .]) |
      (.hooks | map($paths["hooks " + .])) as $refs |
      [$refs[] | select($hooks[.] | hook_manifest and has("on") | not)][0] as $invalid |
      if $invalid then error("hook manifest must be valid and declare \"on\": " + $invalid)
      else . end |
      .hooks = (reduce hook_names[] as $lifecycle ({};
        [$refs[] | select($hooks[.].on == $lifecycle)] as $list |
        if $list == [] then . else .[$lifecycle] = $list end)) |
      .sandbox = ($sandbox == "1") |
      .sandbox_read_paths = ($read | paths) + ($grants.sandbox_read_paths // []) |
      .sandbox_write_paths = ($write | paths) + ($grants.sandbox_write_paths // []) |
      profile_expand($share; $home) |
      if canonical_profile then . else error("invalid resolved profile") end
    ' --args "${resolutions[@]}" 2>&1) || {
    sf_profile_validation_error "$final" 'cannot resolve profile'
    return
  }
  sf_profile_tools "$final" || return
  REPLY=$final
}

# Parse the options that select a profile, then resolve it. Callers that own
# their own flags pass only the ones listed in lib/options.zsh.
sf_profile_resolve_args() {
  local name='' request='{}' flag grant resolved grants=''
  local -a models=() read_paths=() write_paths=()
  integer detect=0

  SF_PROFILE_ERROR=''
  while (( $# )); do
    case $1 in
      -p|--profile)
        [[ -z $name ]] || sf_profile_fail '--profile may only be specified once' || return 2
        [[ $2 =~ '^@?[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$' ]] ||
          sf_profile_fail '--profile must be a slash-separated profile name' || return 2
        name=$2
        shift 2
        ;;
      -m|--model)
        [[ $2 =~ '^@?[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$' ]] ||
          sf_profile_fail '--model must be a slash-separated model name' || return 2
        models+=( "$2" )
        shift 2
        ;;
      --request)
        request=$(jq -ce --argjson base "$request" 'select(type == "object") | $base * .' \
          <<<"$2" 2>/dev/null) || sf_profile_fail '--request requires a JSON object' || return 2
        shift 2
        ;;
      --sandbox-read|--sandbox-write)
        flag=$1
        [[ -n $2 ]] || sf_profile_fail "$flag requires a nonempty path" || return 2
        grant=$2
        if [[ $grant == '~/'* ]]; then
          [[ -n ${HOME-} ]] || sf_profile_fail "$flag cannot expand ~ without HOME" || return 2
          grant="$HOME/${grant#\~/}"
        elif [[ $grant != /* ]]; then
          grant="$PWD/$grant"
        fi
        resolved=${grant:A}
        [[ -e $resolved ]] || sf_profile_fail "$flag path does not exist: $2" || return 2
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
        sf_profile_fail "unknown argument: $1"
        return 2
        ;;
    esac
  done

  if (( detect || ${#read_paths} || ${#write_paths} )); then
    local detected='{"sandbox_read_paths":[],"sandbox_write_paths":[]}'
    if (( detect )); then
      (( $+functions[sf_sandbox_detect] )) || source "$SF_ROOT/lib/sandbox.zsh"
      detected=$(sf_sandbox_detect) || sf_profile_fail 'cannot detect sandbox paths' || return
    fi
    # The read count splits explicit read and write path arguments.
    grants=$(jq -cn --argjson detected "$detected" \
      --argjson reads "${#read_paths}" --args '
        {sandbox_read_paths: ($ARGS.positional[:$reads] + $detected.sandbox_read_paths),
         sandbox_write_paths: ($ARGS.positional[$reads:] + $detected.sandbox_write_paths)}
      ' -- "${read_paths[@]}" "${write_paths[@]}") ||
      sf_profile_fail 'cannot prepare sandbox grants' || return
  fi

  sf_profile_resolve "$name" "${(pj:\n:)models}" "$request" "$grants"
}
