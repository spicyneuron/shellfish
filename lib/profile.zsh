emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_jsonc_read] )) || source "$SF_ROOT/lib/jsonc.zsh"
(( $+functions[sf_cli_diagnostic] )) || source "$SF_ROOT/lib/cli.zsh"
(( $+functions[sf_environment_config_dir] )) || source "$SF_ROOT/lib/environment.zsh"

typeset -g SF_PROFILE_ERROR=''
typeset -g SF_PROFILE_GRANTS='{"sandbox_read_paths":[],"sandbox_write_paths":[]}'

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
  local directory=$1 json="$1/manifest.json" jsonc="$1/manifest.jsonc"
  if [[ ( -e $json || -L $json ) && ( -e $jsonc || -L $jsonc ) ]]; then
    sf_profile_fail "multiple component manifests: $directory"
  elif [[ -f $jsonc && -r $jsonc ]]; then
    REPLY=$jsonc
  elif [[ -f $json && -r $json ]]; then
    REPLY=$json
  else
    sf_profile_fail "cannot read component manifest: $directory"
  fi
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
    files+=( "$REPLY" )
  done
  (( ${#files} )) || { REPLY='[]'; return 0; }
  sf_profile_read_files 'invalid component manifest' "${files[@]}" || return
  projection=$(sf_jq -cn --argjson manifests "$REPLY" '
    include "lib/profile";
    [$ARGS.positional[] as $path | ($path | sub("/[^/]*$"; "")) as $directory |
      ($manifests[$path] | select(tool_manifest) //
        error("invalid tool manifest: " + $path)) as $manifest |
      {name:($directory | split("/") | last), command:($directory + "/run"),
       manifest:$manifest}]
  ' --args "${files[@]}" 2>&1) || {
    sf_profile_validation_error "$projection" 'cannot read tools'
    return
  }
  REPLY=$projection
}

# Merge the selected profiles, apply overrides and defaults, and resolve every
# reference. REPLY is the profile with absolute paths.
sf_profile_resolve() {
  local profile_names=$1 model_override=$2 request_override=$3 backend_override=$4
  local config_dir profile reference resolved manifest='' final name file found='{}' parents
  local -A decoded seen
  local -a files pending references resolutions=()

  SF_PROFILE_ERROR=''
  REPLY=''
  sf_environment_config_dir || sf_profile_fail "$SF_ENVIRONMENT_ERROR" || return
  config_dir=$REPLY
  if [[ -n $profile_names ]]; then
    pending=( ${(f)profile_names} )
  else
    pending=( default )
  fi
  while (( ${#pending} )); do
    files=()
    for name in "${pending[@]}"; do
      [[ -z ${seen[$name]-} ]] || continue
      [[ $name =~ '^@?[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$' ]] ||
        sf_profile_fail "invalid profile name: $name" || return
      seen[$name]=1
      if [[ $name == @* ]]; then
        file="$SF_SHARE/profiles/${name#@}.jsonc"
      else
        file="$config_dir/profiles/$name.jsonc"
        [[ -e $file || -L $file ]] || file="$SF_SHARE/profiles/$name.jsonc"
      fi
      [[ -e $file || -L $file ]] || sf_profile_fail "unknown profile: $name" || return
      files+=( "$file" )
    done
    (( ${#files} )) || break
    sf_profile_read_files 'invalid profile' "${files[@]}" || return
    found=$(jq -cn --argjson previous "$found" --argjson files "$REPLY" \
      '$previous + $files') || sf_profile_fail 'cannot read profiles' || return
    parents=$(sf_jq -rn --argjson files "$REPLY" \
      --arg bundled "$SF_SHARE/profiles" --arg configured "$config_dir/profiles" '
      include "lib/profile";
      $files | profile_map($bundled; $configured) | to_entries[] |
      .key as $name | .value | config_profile([$name]) | .extend[]?
    ' 2>&1) || {
      sf_profile_validation_error "$parents" 'invalid profile'
      return
    }
    pending=( ${(f)parents} )
  done

  sf_jq_fields -rn --argjson files "$found" --arg names "$profile_names" \
    --arg bundled "$SF_SHARE/profiles" --arg configured "$config_dir/profiles" \
    --arg model "$model_override" --argjson request "$request_override" \
    --arg backend "$backend_override" --argjson grants "$SF_PROFILE_GRANTS" '
      include "lib/fields";
      include "lib/profile";
      ($files | profile_map($bundled; $configured)) as $profiles |
      (($names | select(length > 0) | split("\n")) // ["default"]) as $names |
      profile_select($profiles; $names; $model; $request; $backend) |
      .sandbox_read_paths += $grants.sandbox_read_paths |
      .sandbox_write_paths += $grants.sandbox_write_paths |
      entry("profile"; tojson),
      entry("references"; [profile_references(join(" ")) |
        .backend.adapter, .system[], .tools[], .hooks[][]] | unique | join("\n")),
      ("ok" | field)
  ' || {
    sf_profile_validation_error "$REPLY" 'cannot select profile'
    return
  }
  decoded=( "${reply[@]}" )
  profile=$decoded[profile]
  references=( ${(f)decoded[references]} )

  # A reference carries no control characters, so newlines delimit the list.
  for reference in "${references[@]}"; do
    sf_profile_reference "${reference#* }" "${reference%% *}" "$config_dir" || {
      sf_profile_fail "cannot resolve ${reference%% *} reference: ${reference#* }"
      return
    }
    resolved=$REPLY
    case ${reference%% *} in
      system) [[ -f $resolved && -r $resolved ]] ;;
      hooks) [[ -f $resolved && -x $resolved ]] ;;
      *) [[ -d $resolved && -x $resolved/run ]] ;;
    esac || {
      sf_profile_fail "invalid ${reference%% *} reference: ${reference#* }"
      return
    }
    if [[ $reference == 'backends '* ]]; then
      sf_profile_manifest "$resolved" && manifest=$(sf_jsonc_read "$REPLY" 2>&1) || {
        [[ -n $SF_PROFILE_ERROR ]] ||
          sf_profile_validation_error "$manifest" "invalid component manifest: $REPLY"
        return 1
      }
    fi
    resolutions+=( "$reference" "$resolved" )
  done

  final=$(sf_jq -cnce --argjson profile "$profile" --argjson manifest "$manifest" \
    --arg share "$SF_SHARE" --arg home "${HOME:+${HOME:A}}" '
      include "lib/profile";
      ($ARGS.positional | [range(0; length; 2) as $at | {key:.[$at], value:.[$at + 1]}] |
        from_entries) as $paths |
      ($manifest | select(type == "object" and keys == ["endpoint"] and (.endpoint | endpoint)) //
        error("invalid backend manifest")) as $manifest |
      $profile | profile_references(join(" ") as $key | $paths[$key]) |
      .backend.endpoint //= $manifest.endpoint |
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
  local model='' backend=''
  local request='{}' flag grant resolved
  local -a profiles=() read_paths=() write_paths=()
  integer detect=0

  SF_PROFILE_ERROR=''
  while (( $# )); do
    case $1 in
      -p|--profile)
        [[ $2 =~ '^@?[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$' ]] ||
          sf_profile_fail '--profile must be a slash-separated profile name' || return 2
        profiles+=( "$2" )
        shift 2
        ;;
      -m|--model)
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] ||
          sf_profile_fail '--model requires a nonempty value without control characters' || return 2
        model=$2
        shift 2
        ;;
      -b|--backend)
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] ||
          sf_profile_fail '--backend requires a nonempty value without control characters' || return 2
        backend=$2
        shift 2
        ;;
      --request)
        request=$(jq -ce 'select(type == "object")' <<<"$2" 2>/dev/null) ||
          sf_profile_fail '--request requires a JSON object' || return 2
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
    SF_PROFILE_GRANTS=$(jq -cn --argjson detected "$detected" \
      --argjson reads "${#read_paths}" --args '
        {sandbox_read_paths: ($ARGS.positional[:$reads] + $detected.sandbox_read_paths),
         sandbox_write_paths: ($ARGS.positional[$reads:] + $detected.sandbox_write_paths)}
      ' -- "${read_paths[@]}" "${write_paths[@]}") ||
      sf_profile_fail 'cannot prepare sandbox grants' || return
  fi

  sf_profile_resolve "${(pj:\n:)profiles}" "$model" "$request" "$backend"
}
