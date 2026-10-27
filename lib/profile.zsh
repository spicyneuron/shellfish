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

# A reference starting with "/", "~/", or "@" is a path, and anything else is
# a name under DIR in the Shellfish directory, then the bundled one. SUFFIX
# completes a name, not a path. REPLY is the canonical path of what exists.
sf_profile_lookup() {
  local config_dir=$1 dir=$2 reference=$3 suffix=${4-} candidate
  if [[ $reference == /* || $reference == '~/'* || $reference == @* ]]; then
    sf_cli_path "$reference" || return
    candidate=$REPLY
  else
    candidate=$config_dir/$dir/$reference$suffix
    [[ -e $candidate || -L $candidate ]] || candidate=$SF_SHARE/$dir/$reference$suffix
  fi
  [[ -e $candidate || -L $candidate ]] || return 1
  REPLY=${candidate:A}
}

# The named files of one kind, in order, read and validated as a JSON array.
sf_profile_configs() {
  local kind=$1 dir=$2 config_dir=$3 name detail
  shift 3
  local -a names=( "$@" ) files=()
  REPLY='[]'
  (( ${#names} )) || return 0
  for name in "${names[@]}"; do
    sf_profile_lookup "$config_dir" "$dir" "$name" .jsonc ||
      sf_profile_fail "unknown $kind: $name" || return
    files+=( "$REPLY" )
  done
  sf_profile_read_files "invalid $kind" "${(u)files[@]}" || return
  detail=$(sf_jq -cn --argjson files "$REPLY" --arg kind "$kind" '
    include "lib/profile";
    [$ARGS.positional | range(0; length; 2) as $at | .[$at:$at + 2] as [$file, $name] |
      $files[$file] | ["\($kind) \($name)"] as $path |
      if $kind == "model" then config_model($path) else config_sandbox($path) end]
  ' --args "${files[@]:^names}" 2>&1) ||
    sf_profile_validation_error "$detail" 'invalid configuration' || return
  REPLY=$detail
}

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

# Resolve profile REFERENCE with extra model references merged after its own, a
# request override applied last, and sandbox GRANTS from flags appended to its
# sandbox files. REPLY is the profile with absolute paths.
sf_profile_resolve() {
  local name=${1:-default} extra_models=$2 request=${3:-'{}'} grants=${4:-'{}'}
  local config_dir profile models sandbox reference kind resolved selected final
  local backend_manifest='{}' hook_manifests='{}'
  local -a references resolutions=() hook_files=()
  local -A decoded

  SF_PROFILE_ERROR=''
  REPLY=''
  sf_environment_dir || sf_profile_fail "$SF_ENVIRONMENT_ERROR" || return
  config_dir=$REPLY
  sf_profile_lookup "$config_dir" profiles "$name" .jsonc ||
    sf_profile_fail "unknown profile: $name" || return
  profile=$(sf_jsonc_read "$REPLY" 2>&1) ||
    sf_profile_validation_error "$profile" "invalid profile: $REPLY" || return
  sf_jq_fields -rn --argjson profile "$profile" --arg name "$name" '
    include "lib/fields";
    include "lib/profile";
    $profile | config_profile(["profile " + $name]) |
    entry("model"; .model // [] | join("\n")),
    entry("sandbox"; .sandbox // [] | join("\n")),
    ("ok" | field)
  ' || { sf_profile_validation_error "$REPLY" 'invalid configuration'; return; }
  decoded=( "${reply[@]}" )
  [[ -n $decoded[model]$extra_models ]] ||
    sf_profile_fail "profile selects no model: $name" || return
  # A reference carries no control characters, so newlines delimit each list.
  sf_profile_configs model models "$config_dir" ${(f)decoded[model]} ${(f)extra_models} ||
    return
  models=$REPLY
  sf_profile_configs sandbox sandbox "$config_dir" ${(f)decoded[sandbox]} || return
  sandbox=$REPLY

  sf_jq_fields -rn --argjson profile "$profile" --argjson models "$models" \
    --argjson request "$request" '
      include "lib/fields";
      include "lib/profile";
      {model:model_merge($models; $request), system:($profile.system // []),
       tools:($profile.tools // []), hooks:($profile.hooks // [])} |
      if (.tools | length) == (.tools | unique | length) then .
      else error("profile tools must be unique: " + (.tools | join(", "))) end |
      entry("profile"; tojson),
      entry("references"; [["backends", .model.adapter], (.system[] | ["system", .]),
        (.tools[] | ["tools", .]), (.hooks[] | ["hooks", .])] | unique |
        map(join(" ")) | join("\n")),
      ("ok" | field)
  ' || {
    sf_profile_validation_error "$REPLY" 'invalid configuration'
    return
  }
  decoded=( "${reply[@]}" )
  selected=$decoded[profile]
  references=( ${(f)decoded[references]} )

  for reference in "${references[@]}"; do
    kind=${reference%% *}
    sf_profile_lookup "$config_dir" "$kind" "${reference#* }" ||
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
    --argjson sandbox "$sandbox" \
    --arg share "$SF_SHARE" --arg home "${HOME:+${HOME:A}}" '
      include "lib/profile";
      sandbox_merge($sandbox) as $sandbox |
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
      .sandbox = $sandbox.enabled |
      .sandbox_read_paths = $sandbox.read + ($grants.sandbox_read_paths // []) |
      .sandbox_write_paths = $sandbox.write + ($grants.sandbox_write_paths // []) |
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
  local name='' request='{}' flag resolved grants=''
  local -a models=() read_paths=() write_paths=()
  integer detect=0

  SF_PROFILE_ERROR=''
  while (( $# )); do
    case $1 in
      -p|--profile|-m|--model)
        [[ -n $2 && $2 != *[[:cntrl:]]* ]] ||
          sf_profile_fail "$1 requires a reference without control characters" || return 2
        if [[ $1 == (-m|--model) ]]; then
          models+=( "$2" )
        else
          [[ -z $name ]] || sf_profile_fail '--profile may only be specified once' || return 2
          name=$2
        fi
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
        sf_cli_path "$2" || sf_profile_fail "$flag cannot expand ~ without HOME" || return 2
        resolved=$REPLY
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
