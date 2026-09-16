emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_prepare] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_HOOK_ERROR=''

sf_hook_fail() {
  SF_HOOK_ERROR=$1
  REPLY=''
  return 1
}

sf_hook_name() {
  local path=$1 name=$1
  [[ ${name:t} != run ]] || name=${name:h}
  REPLY=${name:t}
}

sf_hook_next_id() {
  local maximum
  maximum=$(printf '%s\n' "${SF_SESSION_RECORDS[@]:1}" | jq -Rs '
    [split("\n")[] | fromjson? | select(.type == "hook_result") | .id | tonumber] |
    max // 0
  ') || return
  REPLY=$(( maximum + 1 ))
}

sf_hook_activity() {
  local lifecycle=$1 id=$2 name=$3 executable=$4 input=$5 render=$6
  REPLY=$(sf_jq -cn --arg lifecycle "$lifecycle" --arg id "$id" --arg name "$name" \
    --arg executable "$executable" --argjson input "$input" --argjson render "$render" '
      include "lib/render";
      (render_component($render;$name;$input;{stdout:"",stderr:"",exit_code:0}) |
       .initial_user_text // "") as $user_text |
      {type:"_hook_activity",hook:$lifecycle,id:$id,name:$name,input:$input,
       executable:$executable} +
      (if $user_text == "" then {} else {user_text:$user_text} end)
    ')
}

sf_hook_result() {
  local lifecycle=$1 id=$2 name=$3 executable=$4 input=$5 render=$6 outcome=$7
  REPLY=$(sf_jq -cn --arg lifecycle "$lifecycle" --arg id "$id" --arg name "$name" \
    --arg executable "$executable" --argjson input "$input" --argjson outcome "$outcome" \
    --argjson render "$render" '
      include "lib/render"; include "lib/session/read";
      render_component($render;$name;$input;$outcome) as $rendered |
      ({type:"hook_result",lifecycle:$lifecycle,id:$id,name:$name,input:$input,
        executable:$executable,exit_code:$outcome.exit_code} +
       (if $rendered.user_text == null then {} else {user_text:$rendered.user_text} end) +
       (if $rendered.model_text == null then {} else {model_text:$rendered.model_text} end)) as $result |
      if $result | canonical_hook_result then $result else error("invalid result") end
    ' 2>/dev/null)
}

# Return the decoded outcome in REPLY and capture metadata in reply.
sf_hook_invoke() {
  setopt local_options no_err_exit
  local session=$1 runtime=$2 component=$3 cwd=$4 input=$5 lifecycle=$6 turn_state=$7
  shift 7
  local command selected max_capture config_dir='' directory projected control_error=''
  local -a arguments environment fields process

  SF_HOOK_ERROR=''
  projected=$(jq -jrn --argjson runtime "$runtime" --argjson component "$component" '
    def field: ., "\u0000";
    ($component.command | field),
    ($component.environment | join(" ") | field),
    ($runtime.harness.max_capture_bytes | tostring | field),
    ($runtime.backend.env_file | field),
    ($runtime.profile.request.model | field),
    ("ok" | field)
  ' 2>/dev/null) || {
    sf_hook_fail 'cannot inspect hook component'
    return
  }
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} == 6 )) && [[ $fields[6] == ok ]] || {
    sf_hook_fail 'cannot inspect hook component'
    return
  }
  command=$fields[1]
  selected=$fields[2]
  max_capture=$fields[3]
  [[ -z $fields[4] ]] || config_dir=${fields[4]:h}
  [[ -f $command && -x $command ]] || {
    sf_hook_fail "hook command is not executable: $command"
    return
  }
  sf_environment_prepare "$runtime" "$selected" || {
    sf_hook_fail "$SF_ENVIRONMENT_ERROR"
    return
  }
  arguments=()
  for selected in $SF_ENVIRONMENT_NAMES; do arguments+=( -u "$selected" ); done
  arguments+=( "${SF_ENVIRONMENT_VALUES[@]}" "$command" "$@" )
  environment=(
    "SHELLFISH_SESSION=${session:A}"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture"
    "SHELLFISH_MODEL=$fields[5]"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY"
    "SHELLFISH_MODE=${SHELLFISH_MODE-}"
    "SHELLFISH_VERBOSE=${SHELLFISH_VERBOSE:-0}"
    "SHELLFISH_CONFIG_DIR=$config_dir"
  )
  if [[ $lifecycle != session_start ]]; then
    environment+=( "SHELLFISH_TURN_ID=$SF_SESSION[turn_id]" "SHELLFISH_TURN_STATE=$turn_state" )
  else
    arguments=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${arguments[@]}" )
  fi
  sf_scratch_create hooks capture || {
    sf_hook_fail 'cannot prepare hook capture'
    return
  }
  directory=$REPLY
  if ! sf_process_run "$directory" "${cwd:A}" "${input:A}" "$max_capture" \
      /usr/bin/env -- "${environment[@]}" /usr/bin/env "${arguments[@]}"; then
    rm -rf -- "$directory"
    sf_hook_fail "$SF_PROCESS_ERROR"
    return
  fi
  process=( "${reply[@]}" )
  if (( process[3] + process[4] + process[5] > max_capture )); then
    control_error='hook output exceeds capture limit'
  fi
  REPLY=$(sf_jq -cn --argjson exit_code "$process[1]" --argjson interrupted "$process[2]" \
    --rawfile stdout "$directory/stdout" --rawfile stderr "$directory/stderr" \
    --slurpfile controls "$directory/control" --arg control_error "$control_error" '
      include "lib/session/read";
      ($controls | if length == 0 then {}
       elif length == 1 and (.[0] | type == "object") then .[0]
       else null end) as $control |
      (if $control == null then "malformed control data"
       elif ($control | if has("state") then
          .state | type == "array" and all(.[];
            type == "object" and keys == ["name","value"] and
            ({type:"state"} + . | canonical_state))
        else true end) | not then "invalid state control"
       else $control_error end) as $error |
      {exit_code:$exit_code,interrupted:($interrupted != 0),
       stdout:$stdout,stderr:$stderr,
       states:(if $error == "" then [$control.state[]? | {type:"state"} + .] else [] end),
       control:(if $error == "" then ($control | del(.state)) else {} end)} +
      (if $error == "" then {} else {control_error:$error} end)
    ' 2>/dev/null) || {
    rm -rf -- "$directory"
    sf_hook_fail 'cannot decode hook result'
    return
  }
  rm -rf -- "$directory"
  reply=( "$process[1]" "$process[3]" "$process[4]" "$process[5]" )
  (( ! process[2] )) || return $process[1]
}
