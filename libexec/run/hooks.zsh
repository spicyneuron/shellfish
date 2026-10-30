emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_run_component_begin] )) || source "$SF_ROOT/libexec/run/component.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

# The lifecycle's invocation plan. A prompt naming a command runs only that
# command, with its arguments as input.
typeset -gA SF_HOOK_PLAN=()

sf_run_hook_project() {
  local lifecycle=$1 input=$2
  sf_jq_fields -rn --argjson model "$SF_RUN[model]" --argjson hooks "$SF_RUN[hooks]" \
    --argjson commands "$SF_RUN[commands]" --arg lifecycle "$lifecycle" --arg input "$input" '
      include "lib/fields";
      entry("model"; $model.request.model),
      ([if $lifecycle == "user_prompt_submit" then first($commands[] |
        .command[:-4] as $directory | .manifest.arguments as $arguments |
        (.name, .manifest.aliases[]?) | ("/" + .) as $prefix |
        if $input == $prefix then [$directory, ""]
        elif $arguments != null and ($input | startswith($prefix + " ")) and
          ($input | contains("\n") | not) then
          [$directory, $input[$prefix | length:] | sub("^[[:space:]]+"; "")]
        else empty end) else empty end] | first) as $command |
      if $command == null then
        entry("hooks"; [$hooks[] | select(.manifest.on == $lifecycle) | .command[:-4]] |
          join("\n"))
      else
        entry("command"; $command[0]), entry("arguments"; $command[1]),
        entry("catalog"; [$commands[] | {name} + (.manifest |
          {aliases, arguments, description} | with_entries(select(.value != null)))] | tojson)
      end,
      ("ok" | field)
    ' || return 1
  SF_HOOK_PLAN=( "${reply[@]}" )
}

sf_run_hook_manifest() {
  local command=$1 lifecycle=$2 input=$3 id=$4 max_capture=$5 components=$6
  sf_jq_fields -cn --argjson components "$components" --arg command "$command/run" \
    --arg lifecycle "$lifecycle" --arg input "$input" --arg id "$id" \
    --argjson max_capture "$max_capture" '
    include "lib/fields";
    include "lib/profile";
    first($components[] | select(.command == $command) | .manifest) as $manifest |
    if $manifest.match == null or ($input | test($manifest.match.pattern)) then
      # The script name is the path below hooks/ or commands/, as profiles write it.
      {template:$manifest.user_text, input:$input,
       script:($command | rtrimstr("/run") |
         if test("/(hooks|commands)/") then sub(".*/(hooks|commands)/"; "") else split("/") | last end),
       draft:({type:"_draft",lifecycle:$lifecycle,id:$id,
         user_text:render_template($manifest.user_text; {input:$input})} +
         ($manifest | with_entries(select(.key == "user_preview_lines")))),
       max_capture:(if $manifest.max_capture_kb then $manifest.max_capture_kb * 1024
         else $max_capture end)} as $component |
      entry("component"; $component | tojson),
      entry("draft"; $component.draft | if .user_text == "" then "" else tojson end),
      entry("max_capture"; $component.max_capture | tostring)
    else entry("component"; "") end,
    ("ok" | field)
  ' || { REPLY="invalid hook manifest: $command"; return 1; }
}

# The last control line wins. It is validated when the hook settles.
sf_run_hook_line() {
  sf_run_component_line "$1" action argv profile reason || return
  [[ -z $REPLY ]] || control=$REPLY
}

sf_run_hook_complete() {
  local lifecycle=$1 outcome=$2 command=$3
  local -A settled
  sf_jq_fields -cn --argjson component "$SF_COMPONENT[values]" --argjson outcome "$outcome" \
    --argjson control "$control" --arg lifecycle "$lifecycle" '
    include "lib/fields";
    include "lib/session";
    include "lib/profile";
    ({user_prompt_submit:["deny","handoff","session_update"],
      permission_request:["allow","deny"],pre_tool_use:["deny"],
      stop:["deny"]}[$lifecycle] // []) as $actions |
    if $control == {} or ($control | (.action | IN($actions[])) and
      if .action == "handoff" then keys == ["action","argv"] and
        (.argv | type == "array" and length > 0 and all(.[]; type == "string"))
      elif .action == "session_update" then keys == ["action","profile"] and
        (.profile | type == "object")
      elif .action == "deny" then keys == ["action"] or
        (keys == ["action","reason"] and (.reason | type == "string"))
      else keys == ["action"] end) then . else error("invalid control") end |
    ($component.draft + {type:"hook_result",
      user_text:render_template($component.template; $component + $outcome),
      model_text:($outcome.output.stdout | if . == "" then . else
        "<context script=\"\($component.script | @html)\">\n" + . +
        (if endswith("\n") then "" else "\n" end) + "</context>" end)} +
      (if $control.action == "deny" then $control else {} end) |
      with_entries(select(.value != "")) |
      if (has("user_text") or has("model_text") or has("action")) | not then entry("result"; "")
      elif canonical_hook_result then entry("result"; tojson)
      else error("invalid hook result") end,
      entry("model_feedback"; has("model_text") | tostring)),
    entry("action"; $control.action // ""), entry("reason"; $control.reason // ""),
    entry("payload"; $control | .argv // .profile | if . == null then "" else tojson end),
    ("ok" | field)
  ' || { REPLY="$lifecycle hook returned invalid control or result: $command"; return 1; }
  settled=( "${reply[@]}" )
  action=$settled[action] reason=$settled[reason] payload=$settled[payload]
  if [[ -n $settled[result] ]]; then
    sf_run_append "$SF_COMPONENT[session]" "$settled[result]" || return
    (( SF_RUN[hook_id] += 1 ))
    [[ $settled[model_feedback] != true ]] || model_feedback=1
  fi
}

# Run each hook with the lifecycle's original input and arguments. A successful
# action ends the list; no action leaves reply empty.
sf_run_hooks() {
  setopt local_options no_err_exit
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local command input config_dir directory error='' control action='' reason='' payload=''
  local kind=hooks
  local -a hooks environment
  local -A SF_COMPONENT=() prepared
  integer max_capture model_feedback=0

  SF_RUN_HOOK_ERROR=''
  reply=( action '' reason '' payload '' )
  [[ " $SF_RUN[lifecycles] " == *" $lifecycle "* ]] || return 0
  sf_run_hook_project "$lifecycle" "$content" || {
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  hooks=( ${(f)SF_HOOK_PLAN[hooks]} )
  if [[ -n $SF_HOOK_PLAN[command] ]]; then
    kind=commands hooks=( "$SF_HOOK_PLAN[command]" ) content=$SF_HOOK_PLAN[arguments]
  fi
  (( ${#hooks} )) || return 0
  sf_environment_load || {
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
    "SHELLFISH_CONFIG=$SF_RUN[config]"
    "SHELLFISH_MODEL=$SF_HOOK_PLAN[model]"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY"
    "SHELLFISH_MODE=${SHELLFISH_MODE-}"
    "SHELLFISH_VERBOSE=${SHELLFISH_VERBOSE:-0}"
    "SHELLFISH_DIR=$config_dir"
    "SHELLFISH_SHARE_DIR=$SF_SHARE"
  )
  [[ $kind != commands ]] || environment+=( "SHELLFISH_COMMANDS=$SF_HOOK_PLAN[catalog]" )
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
      sf_run_hook_manifest "$command" "$lifecycle" "$content" \
        "$SF_RUN[hook_id]" "$SF_RUN[max_capture]" "$SF_RUN[$kind]" || { error=$REPLY; break; }
      prepared=( "${reply[@]}" )
      [[ -n $prepared[component] ]] || continue
      max_capture=$prepared[max_capture]
      sf_scratch_directory hook || { error='cannot prepare hook capture'; break; }
      directory=$REPLY
      # A command's prompt is never submitted.
      [[ $kind == commands ]] && control='{"action":"deny"}' || control='{}'
      sf_run_component_begin "$session" "$prepared[component]"
      if [[ -n $prepared[draft] ]] && ! sf_run_emit "$prepared[draft]"; then
        error='cannot emit hook draft'
      elif ! sf_run_component_execute "$directory" "${SF_RUN[cwd]:A}" "$input" "$max_capture" \
          "$max_capture" sf_run_hook_line /usr/bin/env "${environment[@]}" "SHELLFISH_MAX_CAPTURE_KB=$(( max_capture / 1024 ))" \
          "$command/run" "$@"; then
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
              sf_run_hook_complete "$lifecycle" "$REPLY" "$command" || error=$REPLY
            fi ;;
        esac
      fi
      rm -rf -- "$directory"
      [[ -z $error && -z $action ]] || break
    done
  fi
  rm -f -- "$input"
  if [[ -z $error && $lifecycle == stop && $action == deny ]] &&
      (( ! model_feedback )); then
    error='stop hook denied without model feedback'
  fi
  [[ -z $error ]] || { SF_RUN_HOOK_ERROR=$error; return 1; }
  reply=( action "$action" reason "$reason" payload "$payload" )
}
