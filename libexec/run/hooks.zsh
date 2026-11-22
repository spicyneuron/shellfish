emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload -F zsh/files b:zf_rm

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_scratch] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_run_component_begin] )) || source "$SF_ROOT/libexec/run/component.zsh"

# Model, command catalog and arguments, a usage result for a command given
# arguments it does not take, then directory, capture limit, draft and
# component for each hook. An unmatched hook has no capture limit.
sf_run_hook_project() {
  local lifecycle=$1 input=$2 available=$3
  sf_jq_fields -rn --argjson model "$SF_RUN[model]" --argjson hooks "$SF_RUN[hooks]" \
    --argjson commands "$available" --arg lifecycle "$lifecycle" --arg input "$input" \
    --argjson max_capture "$SF_RUN[max_capture]" --arg id "$SF_RUN[hook_id]" '
      include "lib/fields";
      include "lib/profile";
      def planned($input):
        .command[:-4] as $directory | .manifest as $manifest |
        if $manifest.match == null or ($input | test($manifest.match.pattern)) then
          # The script name is the path below hooks/ or commands/, as profiles write it.
          {template:$manifest.user_text, input:$input,
           script:($directory |
             if test("/(hooks|commands)/") then sub(".*/(hooks|commands)/"; "") else split("/") | last end),
           draft:({type:"_draft",lifecycle:$lifecycle,
             user_text:render_template($manifest.user_text; {input:$input})} +
             ($manifest | with_entries(select(.key == "user_preview_lines")))),
           max_capture:(if $manifest.max_capture_kb then $manifest.max_capture_kb * 1024
             else $max_capture end)} |
          [$directory, (.max_capture | tostring),
           (.draft | if .user_text == "" then "" else tojson end), tojson]
        else [$directory, "", "", ""] end | .[] | field;
      ($model.request.model | field),
      # A name ends at whitespace or the end of the prompt.
      ([if $lifecycle == "user_prompt_submit" then first($commands[] | . as $component |
        (.name, .manifest.aliases[]?) | ("/" + .) as $prefix |
        $input[$prefix | length:] as $rest |
        select(($input | startswith($prefix)) and ($rest == "" or ($rest | test("^[[:space:]]")))) |
        [$component, ($rest | sub("^[[:space:]]+"; ""))]) else empty end] | first) as $command |
      if $command == null then
        ("" | field), ("" | field), ("" | field),
        ($hooks[] | select(.manifest.on == $lifecycle) | planned($input))
      else
        ([$commands[] | {name} + (.manifest |
          {aliases, arguments, description} | with_entries(select(.value != null)))] | tojson | field),
        ($command[1] | field),
        if $command[0].manifest.arguments == null and $command[1] != "" then
          ({type:"hook_result", id:$id, lifecycle:$lifecycle, action:"deny",
            user_text:"usage: /\($command[0].name)"} | tojson | field)
        else ("" | field), ($command[0] | planned($command[1])) end
      end,
      ("ok" | field)
    '
}

# The last action wins. It is validated when the hook settles.
sf_run_hook_line() {
  local line
  sf_run_component_line "$1" action argv profile reason content || return
  [[ -n $REPLY ]] || return 0
  line=$REPLY
  if [[ $(jq 'has("content")' <<<"$line") == true ]]; then
    sf_run_component_content "$line" || return
  fi
  line=$(jq -c 'del(.content)' <<<"$line") || return
  [[ $line == '{}' ]] || control=$line
}

# IS_COMMAND is true for a command, which may also submit.
sf_run_hook_complete() {
  local lifecycle=$1 outcome=$2 command=$3 is_command=$4
  local -A settled
  print -rl -- "$outcome" "${content[@]}" | sf_jq_fields -cs --argjson component "$SF_COMPONENT[values]" \
    --argjson control "$control" --arg lifecycle "$lifecycle" --arg id "$SF_RUN[hook_id]" \
    --argjson section "${SF_RUN[agent_section]:-0}" --argjson command "$is_command" '
    include "lib/fields";
    include "lib/session";
    include "lib/profile";
    .[0] as $outcome | .[1:] as $content |
    ({user_prompt_submit:["deny","handoff","session_update"],
      permission_request:["approve","deny"],pre_tool_use:["deny"],
      stop:["deny"]}[$lifecycle] // [] |
      if $command then . + ["submit"] else . end) as $actions |
    if $control == {} or ($control | (.action | IN($actions[])) and
      if .action == "handoff" then keys == ["action","argv"] and
        (.argv | type == "array" and length > 0 and all(.[]; type == "string"))
      elif .action == "session_update" then keys == ["action","profile"] and
        (.profile | type == "object")
      elif (.action | IN("approve", "deny")) then keys == ["action"] or
        (keys == ["action","reason"] and (.reason | type == "string"))
      else keys == ["action"] end) then . else error("invalid control") end |
    ($component.draft + {type:"hook_result", id:$id,
      user_text:render_template($component.template; $component + $outcome),
      model_content:([$outcome.output.stdout | select(. != "") |
        ("<context script=\"\($component.script | @html)\">\n" + . +
          (if endswith("\n") then "" else "\n" end) + "</context>") | text_part] + $content)} +
      (if $control.action == "deny" then $control else {} end) |
      with_entries(select(.value != "" and .value != [])) |
      (if $section > 0 then .section = $section else . end) |
      if (has("user_text") or has("model_content") or has("action")) | not then entry("result"; "")
      elif canonical_hook_result then entry("result"; tojson)
      else error("invalid hook result") end,
      entry("model_feedback"; has("model_content") | tostring)),
    entry("action"; $control.action // ""), entry("reason"; $control.reason // ""),
    entry("payload"; $control | .argv // .profile | if . == null then "" else tojson end),
    ("ok" | field)
  ' || { sf_fail "$lifecycle hook returned invalid control or result: $command"; return; }
  settled=( "${reply[@]}" )
  action=$settled[action] reason=$settled[reason] payload=$settled[payload]
  if [[ -n $settled[result] ]]; then
    sf_run_append "$SF_COMPONENT[session]" "$settled[result]" || return
    (( SF_RUN[hook_id] += 1 ))
    [[ $settled[model_feedback] != true ]] || model_feedback=1
  fi
}

# Run each hook with the lifecycle's original input and arguments. A successful
# action ends the list; no action leaves reply empty. --hooks skips commands.
sf_run_hooks() {
  setopt local_options no_err_exit
  local -a watch=()
  local available=$SF_RUN[commands]
  if [[ $1 == --poll ]]; then watch=( "$1" "$2" ); shift 2; fi
  if [[ $1 == --hooks ]]; then available='[]'; shift; fi
  local session=$1 lifecycle=$2 input_text=$3 turn_state=$4 prompt=$3
  shift 4
  local command input config_dir directory error='' control action='' reason='' payload=''
  local catalog draft
  local -a environment content plan
  local -A SF_COMPONENT=()
  integer i max_capture model_feedback=0 max_content=$SF_RUN[max_content] content_bytes=0

  reply=( action '' reason '' payload '' )
  [[ " $SF_RUN[lifecycles] " == *" $lifecycle "* ]] || return 0
  sf_run_hook_project "$lifecycle" "$input_text" "$available" || {
    sf_fail "cannot inspect $lifecycle hooks"
    return
  }
  plan=( "${reply[@]}" )
  if [[ -n $plan[4] ]]; then
    sf_run_append "$session" "$plan[4]" || return
    (( SF_RUN[hook_id] += 1 ))
    reply=( action deny reason '' payload '' )
    return 0
  fi
  (( ${#plan} > 4 )) || { reply=( action '' reason '' payload '' ); return 0; }
  catalog=$plan[2]
  # A prompt naming a command runs only that command, with its arguments as input.
  [[ -z $catalog ]] || input_text=$plan[3]
  sf_environment_load || return
  config_dir=$REPLY
  sf_scratch hook-input || { sf_fail "cannot prepare $lifecycle hook input"; return; }
  input=${REPLY:A}
  # Core values follow configured values so that they win.
  environment=(
    "${SF_ENVIRONMENT_VALUES[@]}"
    "SHELLFISH_SESSION=${session:A}"
    "SHELLFISH_CONFIG=$SF_RUN[config]"
    "SHELLFISH_MODEL=$plan[1]"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY"
    "SHELLFISH_MODE=${SHELLFISH_MODE-}"
    "SHELLFISH_VERBOSE=${SHELLFISH_VERBOSE:-0}"
    "SHELLFISH_DIR=$config_dir"
    "SHELLFISH_SHARE_DIR=$SF_SHARE"
  )
  [[ -z $catalog ]] || environment+=( "SHELLFISH_COMMANDS=$catalog" )
  if [[ $lifecycle != session_start ]]; then
    environment+=( "SHELLFISH_TURN_ID=$SF_RUN[turn_id]" "SHELLFISH_TURN_STATE=$turn_state" )
  else
    environment=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${environment[@]}" )
  fi
  if ! print -rn -- "$input_text" >"$input"; then
    error="cannot prepare $lifecycle hook input"
  else
    for (( i = 5; i <= ${#plan}; i += 4 )); do
      command=$plan[i]
      [[ -d $command && -x $command/run ]] || {
        error="hook command is not executable: $command"
        break
      }
      [[ -n $plan[i+1] ]] || continue
      max_capture=$plan[i+1]
      draft=$plan[i+2]
      content=() content_bytes=0
      sf_scratch -d hook || { error='cannot prepare hook capture'; break; }
      directory=$REPLY
      # A command's prompt is withheld unless the command submits it.
      [[ -n $catalog ]] && control='{"action":"deny"}' || control='{}'
      sf_run_component_begin "$session" "$plan[i+3]"
      # The preceding hook only advanced the ID if it wrote a result.
      if [[ -n $draft ]] && ! sf_run_emit "{\"id\":\"$SF_RUN[hook_id]\",${draft#\{}"; then
        error='cannot emit hook draft'
      elif ! sf_run_component_execute "${watch[@]}" "$directory" "${SF_RUN[cwd]:A}" "$input" "$max_capture" \
          "$max_content" sf_run_hook_line /usr/bin/env "${environment[@]}" "SHELLFISH_MAX_CAPTURE_KB=$(( max_capture / 1024 ))" \
          "SHELLFISH_MAX_CONTENT_KB=$(( max_content / 1024 ))" \
          "$command/run" "$@"; then
        error=$SF_ERROR
      else
        [[ $reply[1] != ok ]] || (( content_bytes <= max_content )) || reply[1]=overflow
        case $reply[1] in
          (cancelled) error="$lifecycle hook cancelled" ;;
          (interrupted)
            SF_RUN[signal_status]=$reply[2]
            error="cannot run $lifecycle hook" ;;
          (invalid) error="$lifecycle hook returned invalid control: $command" ;;
          (overflow) error="$lifecycle hook content exceeds content limit: $command" ;;
          (*)
            if (( reply[2] )); then
              error="$lifecycle hook failed with status $reply[2]: $command"
              [[ ! -s $directory/stderr ]] || error+=": $(<"$directory/stderr")"
            else
              sf_run_hook_complete "$lifecycle" "$REPLY" "$command" \
                "${${catalog:+true}:-false}" || error=$SF_ERROR
            fi ;;
        esac
      fi
      zf_rm -rf -- "$directory"
      [[ -z $error && -z $action ]] || break
    done
  fi
  zf_rm -f -- "$input"
  if [[ -z $error && $lifecycle == stop && $action == deny ]] &&
      (( ! model_feedback )); then
    error='stop hook denied without model feedback'
  fi
  [[ -z $error ]] || { sf_fail "$error"; return; }
  # A submitted prompt then passes through the prompt hooks as typed.
  [[ $action != submit ]] || { sf_run_hooks --hooks "$session" "$lifecycle" "$prompt" "$turn_state"; return; }
  reply=( action "$action" reason "$reason" payload "$payload" )
}
