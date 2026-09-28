emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_run_component_begin] )) || source "$SF_ROOT/libexec/run/component.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

# The lifecycle's invocation plan.
typeset -gA SF_HOOK_PLAN=()

sf_run_hook_project() {
  local profile=$1 lifecycle=$2
  sf_jq_fields -rn --argjson profile "$profile" --arg lifecycle "$lifecycle" '
      include "lib/fields";
      entry("max_capture"; $profile.max_capture_bytes | tostring),
      entry("model"; $profile.request.model),
      entry("profile_env"; $profile.env | tojson),
      entry("hooks"; $profile.hooks[$lifecycle] // [] | join("\n")),
      ("ok" | field)
    ' || return 1
  SF_HOOK_PLAN=( "${reply[@]}" )
}

sf_run_hook_manifest() {
  local command=$1 name=$2 lifecycle=$3 input=$4 id=$5
  sf_profile_read_manifest "${command:h}" || { REPLY=$SF_PROFILE_ERROR; return 1; }
  REPLY=$(sf_jq -cn --argjson manifest "$REPLY" --arg name "$name" \
    --arg lifecycle "$lifecycle" --arg input "$input" --arg id "$id" '
    include "lib/profile";
    include "lib/session";
    include "libexec/run/component";
    if $manifest | hook_manifest then
      component_plan($manifest; {}; $name; $input; {type:"_draft",lifecycle:$lifecycle,id:$id}) +
        {actions:({user_prompt_submit:["block","handoff","session_update"],
          permission_request:["allow","deny"],pre_tool_use:["deny"],
          stop:["continue"]}[$lifecycle] // [])}
    else error("invalid hook manifest") end
  ' 2>/dev/null) || { REPLY="invalid hook manifest: $command"; return 1; }
}

sf_run_hook_complete() {
  local lifecycle=$1 outcome=$2
  local -A settled
  sf_jq_fields -cn --argjson component "$SF_COMPONENT[values]" --argjson outcome "$outcome" \
    --arg lifecycle "$lifecycle" --arg id "$SF_RUN[hook_id]" '
    include "lib/fields";
    include "lib/session";
    include "lib/profile";
    include "libexec/run/component";
    {type:"hook_result",lifecycle:$lifecycle,id:$id} + component_texts($component; $outcome) |
    if (has("user_text") or has("model_text")) | not then entry("result"; "")
    elif canonical_hook_result then entry("result"; tojson)
    else error("invalid hook result") end,
    entry("model_feedback"; has("model_text") | tostring), ("ok" | field)
  ' || { REPLY='cannot decode hook result'; return 1; }
  settled=( "${reply[@]}" )
  if [[ -n $settled[result] ]]; then
    sf_run_append "$SF_COMPONENT[session]" "$settled[result]" || return
    (( SF_RUN[hook_id] += 1 ))
    SF_COMPONENT[live]=0
    [[ $settled[model_feedback] != true ]] || SF_COMPONENT[model_feedback]=1
  fi
}

# Run each hook with the lifecycle's original input and arguments. A successful
# action ends the list; no action leaves reply empty.
sf_run_hooks() {
  setopt local_options no_err_exit
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local command input config_dir directory error='' name component
  local -a hooks environment
  local -A SF_COMPONENT=( action '' reason '' payload '' live 0 )
  integer max_capture model_feedback=0

  SF_RUN_HOOK_ERROR=''
  reply=( action '' reason '' payload '' )
  if (( SF_RUN[hooks_known] )) &&
      [[ " $SF_RUN[hooks] " != *" $lifecycle "* ]]; then
    return 0
  fi
  sf_run_hook_project "$SF_RUN[profile]" "$lifecycle" || {
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  hooks=( ${(f)SF_HOOK_PLAN[hooks]} )
  (( ${#hooks} )) || return 0
  max_capture=$SF_HOOK_PLAN[max_capture]
  sf_environment_load '' "$SF_HOOK_PLAN[profile_env]" || {
    SF_RUN_HOOK_ERROR=$SF_ENVIRONMENT_ERROR
    return 1
  }
  config_dir=$REPLY
  sf_scratch_file hook-input || { SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"; return 1; }
  input=${REPLY:A}
  # Core values follow configured values so that they win.
  environment=(
    "${SF_ENVIRONMENT_VALUES[@]}"
    "SHELLFISH_SESSION=${session:A}"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture"
    "SHELLFISH_MODEL=$SF_HOOK_PLAN[model]"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY"
    "SHELLFISH_MODE=${SHELLFISH_MODE-}"
    "SHELLFISH_VERBOSE=${SHELLFISH_VERBOSE:-0}"
    "SHELLFISH_CONFIG_DIR=$config_dir"
    "SHELLFISH_SHARE_DIR=$SF_SHARE"
  )
  if [[ $lifecycle != session_start ]]; then
    environment+=( "SHELLFISH_TURN_ID=$SF_RUN[turn_id]" "SHELLFISH_TURN_STATE=$turn_state" )
  else
    environment=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${environment[@]}" )
  fi
  if ! print -rn -- "$content" >"$input"; then
    error="cannot prepare $lifecycle hook input"
  else
    for command in "${hooks[@]}"; do
      [[ -d $command && -x $command/run ]] || {
        error="hook command is not executable: $command"
        break
      }
      if [[ $command == "$SF_SHARE/hooks/"* ]]; then
        name=${command#"$SF_SHARE/hooks/"}
      elif [[ $command == "$config_dir/hooks/"* ]]; then
        name=${command#"$config_dir/hooks/"}
      else
        name=$command
      fi
      sf_run_hook_manifest "$command/run" "$name" "$lifecycle" "$content" \
        "$SF_RUN[hook_id]" || { error=$REPLY; break; }
      component=$REPLY
      sf_scratch_directory hook || { error='cannot prepare hook capture'; break; }
      directory=$REPLY
      if ! sf_run_component_begin "$session" "$component"; then
        error='cannot emit hook draft'
      elif ! sf_run_component_execute "$directory" "${SF_RUN[cwd]:A}" "$input" "$max_capture" \
          /usr/bin/env "${environment[@]}" "$command/run" "$@"; then
        error=$REPLY
      else
        case $reply[1] in
          (interrupted)
            SF_RUN[signal_status]=$reply[2]
            error="cannot run $lifecycle hook" ;;
          (invalid) error="$lifecycle hook returned invalid control: $command" ;;
          (overflow) error="$lifecycle hook output exceeds capture limit: $command" ;;
          (*)
            if (( reply[2] )); then
              error="$lifecycle hook failed with status $reply[2]: $command"
              [[ ! -s $directory/stderr ]] || error+=": $(<"$directory/stderr")"
            else
              sf_run_hook_complete "$lifecycle" "$REPLY" || error=$REPLY
            fi ;;
        esac
      fi
      rm -rf -- "$directory"
      # A draft that nothing settled leaves no trace.
      sf_run_component_clear || error=${error:-cannot emit hook draft}
      (( model_feedback |= SF_COMPONENT[model_feedback] ))
      [[ -z $error && -z $SF_COMPONENT[action] ]] || break
    done
  fi
  rm -f -- "$input"
  if [[ -z $error && $lifecycle == stop && $SF_COMPONENT[action] == continue ]] &&
      (( ! model_feedback )); then
    error='stop hook continued without model feedback'
  fi
  [[ -z $error ]] || { SF_RUN_HOOK_ERROR=$error; return 1; }
  reply=( action "$SF_COMPONENT[action]" reason "$SF_COMPONENT[reason]"
    payload "$SF_COMPONENT[payload]" )
}
