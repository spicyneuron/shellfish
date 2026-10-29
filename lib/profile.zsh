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
  local file
  sf_profile_manifest "$1" || return
  file=$REPLY
  [[ -n $file ]] || { REPLY='{}'; return 0; }
  REPLY=$(sf_jsonc_read "$file" 2>&1) ||
    sf_profile_validation_error "$REPLY" "invalid component manifest: $file"
}

# A reference starting with "/", "~/", "./", "../", or "@" is a path, and
# anything else is a name under DIR in the Shellfish directory, then the bundled
# one. Relative paths in config files and list options are made absolute before
# lookup, so one here is from -p and resolves against PWD. SUFFIX completes a
# name, not a path. REPLY is the canonical path of what exists.
sf_profile_lookup() {
  local config_dir=$1 dir=$2 reference=$3 suffix=${4-} candidate
  if [[ $reference == (/|'~/'|./|../|@)* ]]; then
    sf_cli_path "$reference" || return
    candidate=$REPLY
  else
    candidate=$config_dir/$dir/$reference$suffix
    [[ -e $candidate || -L $candidate ]] || candidate=$SF_SHARE/$dir/$reference$suffix
  fi
  [[ -e $candidate || -L $candidate ]] || return 1
  REPLY=${candidate:A}
}

# A model or sandbox list with each reference replaced by its file, read,
# validated, and made relative to its own directory. NAMES are the references
# in ITEMS, which already holds any inline values validated.
sf_profile_configs() {
  local kind=$1 dir=$2 config_dir=$3 items=$4 name contents detail
  shift 4
  local -a names=( "$@" ) files=()
  (( ${#names} )) || { REPLY=$items; return 0; }
  for name in "${names[@]}"; do
    sf_profile_lookup "$config_dir" "$dir" "$name" .jsonc ||
      sf_profile_fail "unknown $kind: $name" || return
    files+=( "$REPLY" )
  done
  sf_profile_read_files "invalid $kind" "${(u)files[@]}" || return
  contents=$REPLY
  detail=$(sf_jq -cn --argjson items "$items" --argjson contents "$contents" \
    --arg kind "$kind" '
    include "lib/profile";
    ($ARGS.positional | [range(0; length; 2) as $at | {key:.[$at + 1], value:.[$at]}] |
      from_entries) as $files |
    [$items[] | if type == "string" then
      $files[.] as $file | ["\($kind) \(.)"] as $path | $contents[$file] |
      if $kind == "model" then config_model($path) else config_sandbox($path) end |
      config_relative($kind; $file | sub("/[^/]*$"; ""))
    else . end]
  ' --args "${files[@]:^names}" 2>&1) ||
    sf_profile_validation_error "$detail" 'invalid configuration' || return
  REPLY=$detail
}

# Resolve validated model items independently of a profile.
sf_profile_model() {
  local config_dir=$1 items=$2 names model adapter resolved final
  names=$(jq -r '.[] | strings' <<<"$items") ||
    sf_profile_fail 'cannot read model references' || return
  sf_profile_configs model models "$config_dir" "$items" ${(f)names} || return
  model=$(sf_jq -cn --argjson models "$REPLY" '
    include "lib/profile";
    model_merge($models)
  ' 2>&1) || sf_profile_validation_error "$model" 'invalid model' || return
  adapter=$(jq -r '.adapter' <<<"$model") ||
    sf_profile_fail 'cannot read model adapter' || return
  sf_profile_lookup "$config_dir" backends "$adapter" ||
    sf_profile_fail "cannot resolve backends reference: $adapter" || return
  resolved=$REPLY
  [[ -d $resolved && -x $resolved/run ]] ||
    sf_profile_fail "invalid backends reference: $adapter" || return
  sf_profile_read_manifest "$resolved" || return
  final=$(sf_jq -nce --argjson model "$model" --arg adapter "$resolved" \
      --argjson manifest "$REPLY" '
    include "lib/profile";
    ($manifest | select(type == "object" and (keys - ["endpoint"]) == [] and
      ((has("endpoint") | not) or (.endpoint | endpoint))) //
      error("invalid backend manifest")) as $manifest |
    $model | .adapter = $adapter | .endpoint //= $manifest.endpoint |
    if .endpoint == null then error("backend endpoint is required") else . end |
    if canonical_model then . else error("invalid resolved model") end
  ' 2>&1) || sf_profile_validation_error "$final" 'cannot resolve model' || return
  REPLY=$final
}

# The tools or hooks of an expanded profile, read live from their manifests.
sf_profile_components() {
  local kind=$1 profile=$2 directory projection
  local -a directories files=()
  projection=$(jq -r --arg kind "$kind" '.[$kind][]' <<<"$profile") ||
    sf_profile_fail "cannot read profile $kind" || return
  directories=( ${(f)projection} )
  for directory in "${directories[@]}"; do
    [[ -d $directory && -x $directory/run ]] ||
      sf_profile_fail "invalid $kind reference: $directory" || return
    sf_profile_manifest "$directory" || return
    [[ -z $REPLY ]] || files+=( "$REPLY" )
  done
  REPLY='{}'
  (( ! ${#files} )) || sf_profile_read_files 'invalid component manifest' "${files[@]}" || return
  projection=$(sf_jq -cn --argjson manifests "$REPLY" --arg kind "$kind" '
    include "lib/profile";
    ($manifests | with_entries(.key |= sub("/[^/]*$"; ""))) as $manifests |
    [$ARGS.positional[] as $directory |
      (($manifests[$directory] // {}) |
        if $kind == "tools" then select(tool_manifest) //
          error("invalid tool manifest: " + $directory)
        else select(hook_manifest and has("on")) //
          error("hook manifest must be valid and declare \"on\": " + $directory) end
      ) as $manifest |
      {name:($directory | split("/") | last), command:($directory + "/run"),
       manifest:$manifest}]
  ' --args "${directories[@]}" 2>&1) || {
    sf_profile_validation_error "$projection" "cannot read $kind"
    return
  }
  REPLY=$projection
}

# Resolve profile REFERENCE with the lists of options EXTRA appended to its own,
# EXTRA's relative paths resolving against PWD. EXTRA's model list selects the
# model, or models/default without one. REPLY is {profile, model}, frozen with
# absolute paths.
sf_profile_resolve() {
  local name=${1:-default} extra=${2:-'{}'}
  local config_dir file profile config model sandbox reference kind resolved final
  local -a references resolutions=() system_files=()
  local -A decoded

  SF_PROFILE_ERROR=''
  REPLY=''
  sf_environment_dir || sf_profile_fail "$SF_ENVIRONMENT_ERROR" || return
  config_dir=$REPLY
  # Without -p, profiles/default.jsonc is the base when it exists.
  if sf_profile_lookup "$config_dir" profiles "$name" .jsonc; then
    file=$REPLY
    profile=$(sf_jsonc_read "$file" 2>&1) ||
      sf_profile_validation_error "$profile" "invalid profile: $file" || return
  else
    [[ -z $1 ]] || sf_profile_fail "unknown profile: $name" || return
    file='' profile='{}'
  fi
  sf_jq_fields -rn --argjson profile "$profile" --argjson extra "$extra" \
    --arg name "$name" --arg dir "${file:+${file:h}}" --arg cwd "${PWD:A}" '
    include "lib/fields";
    include "lib/profile";
    ($extra | config_profile(["options"]; profile_fields + ["model"]) |
      config_relative("profile"; $cwd)) as $extra |
    $profile | config_profile(["profile " + $name]) | config_relative("profile"; $dir) |
    reduce profile_fields[] as $field (.; .[$field] += $extra[$field]) |
    .model = (if $extra.model == [] then ["default"] else $extra.model end) |
    reduce ("system", "tools", "hooks") as $field (.;
      .[$field] |= reduce .[] as $item ([]; if index([$item]) then . else . + [$item] end)) |
    entry("profile"; tojson),
    entry("models"; .model | tojson), entry("sandboxes"; .sandbox | tojson),
    # A reference carries no control characters, so newlines delimit the list.
    entry("sandbox"; [.sandbox[] | strings] | join("\n")),
    ("ok" | field)
  ' || { sf_profile_validation_error "$REPLY" 'invalid configuration'; return; }
  decoded=( "${reply[@]}" )
  profile=$decoded[profile]
  if [[ $decoded[models] == '["default"]' ]] &&
      ! sf_profile_lookup "$config_dir" models default .jsonc; then
    sf_profile_fail 'no model selected: run shellfish init, or pass -m'
    return
  fi
  sf_profile_model "$config_dir" "$decoded[models]" || return
  model=$REPLY
  sf_profile_configs sandbox sandbox "$config_dir" "$decoded[sandboxes]" \
    ${(f)decoded[sandbox]} || return
  sandbox=$REPLY

  sf_jq_fields -rn --argjson profile "$profile" --argjson model "$model" \
    --argjson sandbox "$sandbox" '
      include "lib/fields";
      include "lib/profile";
      {profile:($profile | del(.model) | .sandbox = sandbox_merge($sandbox)),
       model:$model} |
      entry("config"; tojson),
      entry("references"; [.profile | (.system[] | strings | ["system", .]),
        (.tools[] | ["tools", .]), (.hooks[] | ["hooks", .])] | unique |
        map(join(" ")) | join("\n")),
      ("ok" | field)
  ' || {
    sf_profile_validation_error "$REPLY" 'invalid configuration'
    return
  }
  decoded=( "${reply[@]}" )
  config=$decoded[config]
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
    [[ $kind != system ]] || system_files+=( --rawfile "$reference" "$resolved" )
    resolutions+=( "$reference" "$resolved" )
  done

  # System files are read into one text, like model and sandbox files.
  final=$(sf_jq -nce --argjson config "$config" \
    --arg share "$SF_SHARE" --arg home "${HOME:+${HOME:A}}" "${system_files[@]}" '
      include "lib/profile";
      ($ARGS.positional | [range(0; length; 2) as $at | {key:.[$at], value:.[$at + 1]}] |
        from_entries) as $paths |
      $config |
      .profile.system |= ([.[] | if type == "string" then
          $ARGS.named["system " + .] as $text |
          if $text | index("\u0000") then error("system file contains NUL bytes: " + .)
          else $text end
        else .text end | sub("\n+$"; "") | select(. != "")] | join("\n\n") |
        if . == "" then [] else [{text:.}] end) |
      .profile.tools |= map($paths["tools " + .]) |
      .profile.hooks |= map($paths["hooks " + .]) |
      header_expand($share; $home) |
      if (.profile | canonical_profile) and (.model | canonical_model) then .
      else error("invalid resolved profile") end
    ' --args "${resolutions[@]}" 2>&1) || {
    sf_profile_validation_error "$final" 'cannot resolve profile'
    return
  }
  REPLY=$final
}

# Parse the options that select a profile and model, then resolve them. Each
# list option takes a reference or an inline JSON object and appends to its
# list: the profile's, or for -m the model list.
# Callers that own their own flags pass only the ones listed in lib/options.zsh.
sf_profile_resolve_args() {
  local name='' extra detected='null'
  local -a items=()
  local -A fields=( -m model --model model --sandbox sandbox --system system
    -t tools --tool tools --hook hooks )

  SF_PROFILE_ERROR=''
  while (( $# )); do
    case $1 in
      -p|--profile|-m|--model|--sandbox|--system|-t|--tool|--hook)
        [[ -n $2 && ( $2 == '{'* || $2 != *[[:cntrl:]]* ) ]] ||
          sf_profile_fail "$1 requires a reference or JSON object" || return 2
        if [[ $1 == (-p|--profile) ]]; then
          [[ -z $name ]] || sf_profile_fail '--profile may only be specified once' || return 2
          name=$2
        else
          items+=( "$1" "$fields[$1]" "$2" )
        fi
        shift 2
        ;;
      --sandbox-auto)
        (( $+functions[sf_sandbox_detect] )) || source "$SF_ROOT/lib/sandbox.zsh"
        detected=$(sf_sandbox_detect) || sf_profile_fail 'cannot detect sandbox paths' || return
        shift
        ;;
      *)
        sf_profile_fail "unknown argument: $1"
        return 2
        ;;
    esac
  done

  (( ${#items} )) || [[ $detected != null ]] || { sf_profile_resolve "$name"; return; }
  extra=$(jq -cn --argjson detected "$detected" '
    reduce ($ARGS.positional | range(0; length; 3) as $at | .[$at:$at + 3]) as
      [$flag, $field, $value] ({}; .[$field] += [
        if $value | startswith("{") then ($value | try fromjson catch null | objects) //
          error($flag + " requires a reference or JSON object")
        else $value end]) |
    if $detected then .sandbox += [$detected] else . end
  ' --args -- "${items[@]}" 2>&1) || {
    sf_cli_diagnostic "$extra"
    sf_profile_fail "$REPLY"
    return 2
  }
  sf_profile_resolve "$name" "$extra"
}
