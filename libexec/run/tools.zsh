emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -g SF_RUN_TOOL_ERROR=''

sf_run_tool_plan() {
  local runtime=$1 id=$2 name=$3 input=$4 projection
  local -a fields
  projection=$(sf_jq -jrn --argjson runtime "$runtime" --arg id "$id" --arg name "$name" \
    --argjson input "$input" --argjson turn "$SF_RUN[turn_id]" '
      include "lib/runtime";
      def field: ., "\u0000";
      [$runtime.harness.tools[] | select(.name == $name)][0] as $tool |
      ($tool.manifest.render // tool_render_defaults) as $render |
      (render_component($render;$name;$input;{stdout:"",stderr:"",exit_code:0})) as $rendered |
      (if $tool == null or ($runtime.harness.sandbox | not) then {decision:"none"}
       elif (($input.request_sandbox_bypass // false) | type) != "boolean" then
         {decision:"deny",reason:"sandbox bypass is not allowed"}
       elif ($input.request_sandbox_bypass // false) == false then {decision:"none"}
       elif ($tool.manifest.allow_sandbox_bypass // false) != true then
         {decision:"deny",reason:"sandbox bypass is not allowed"}
       elif ($input.sandbox_bypass_reason? | type) != "string" or
           $input.sandbox_bypass_reason == "" then
         {decision:"failure",reason:"sandbox bypass reason is required"}
       else {decision:"request",reason:$input.sandbox_bypass_reason} end) as $permission |
      ({turn_id:$turn,tool_name:$name,tool_use_id:$id,tool_input:$input} | tojson | field),
      ({type:"_tool_activity",id:$id,name:$name,input:$input} +
        (if $rendered.initial_user_text == null then {}
         else {user_text:$rendered.initial_user_text} end) | tojson | field),
      ($permission.decision | field), ($permission.reason // "" | field),
      ($rendered.permission_user_text // "" | field),
      ($tool.command // "" | field), (($tool.manifest.environment // []) | join(" ") | field),
      ($tool.settings // "" | field), ($runtime.harness.max_capture_bytes | tostring | field),
      ($runtime.harness.fence | field), ($runtime.backend.env_file | field),
      ($input | del(.request_sandbox_bypass,.sandbox_bypass_reason) | tojson | field),
      ($runtime.harness.sandbox and ($tool.manifest.sandbox // false) and
        (($input.request_sandbox_bypass // false) | not) | tostring | field),
      ($runtime.harness.sandbox_read_paths | join("\n") | field),
      ($runtime.harness.sandbox_write_paths | join("\n") | field),
      ($render | tojson | field), ("ok" | field)
    ' 2>/dev/null) || { SF_RUN_TOOL_ERROR='cannot inspect tool'; return 1; }
  fields=( "${(@0)${projection%$'\0'}}" )
  (( ${#fields} == 17 )) && [[ $fields[17] == ok ]] || {
    SF_RUN_TOOL_ERROR='cannot inspect tool'
    return 1
  }
  reply=( "${(@)fields[1,16]}" )
}

sf_run_tool_refused() {
  local reason=$1
  integer exit_code=$2
  REPLY=$(jq -cn --arg reason "$reason" --argjson exit_code "$exit_code" \
    '{output:{stdout:"",stderr:"",exit_code:$exit_code},states:[],reason:$reason}')
}

sf_run_tool_bound() {
  local source=$1 destination=$2
  integer limit=$3 bytes room
  local marker=$'[output truncated]\n'
  bytes=$(wc -c <"$source") || return
  if (( bytes <= limit )); then
    cat "$source" >"$destination"
  elif (( limit <= ${#marker} )); then
    print -rn -- "${marker[1,limit]}" >"$destination"
  else
    room=$(( limit - ${#marker} ))
    print -rn -- "$marker" >"$destination" && tail -c "$room" "$source" >>"$destination"
  fi
}

sf_run_tool_execute() {
  setopt local_options no_err_exit
  local session=$1 command=$2 selected=$3 settings=$4 fence=$6
  local env_file=$7 execution_input=$8 sandbox=$9 read_paths=${10} write_paths=${11}
  local tool_directory=${12} cwd=$SF_RUN[cwd] capture stdin bounded_stdout bounded_stderr
  local config_dir='' expose
  local -a arguments environment names process_command process sandbox_arguments
  integer max_capture=$5 control_bytes budget stderr_bytes denied=0

  SF_RUN_TOOL_ERROR=''
  [[ -z $env_file ]] || config_dir=${env_file:h}
  sf_environment_load "$env_file" "$selected" || {
    SF_RUN_TOOL_ERROR=$SF_ENVIRONMENT_ERROR
    return 1
  }
  [[ -d $tool_directory ]] || { SF_RUN_TOOL_ERROR='tool temporary directory is unavailable'; return 1; }
  sf_scratch_create tools capture || { SF_RUN_TOOL_ERROR='cannot prepare tool capture'; return 1; }
  capture=$REPLY
  {
  stdin="$tool_directory/input"
  print -r -- "$execution_input" >"$stdin" || {
    SF_RUN_TOOL_ERROR='cannot prepare tool input'
    return 1
  }
  environment=(
    "HOME=${HOME:-$cwd}" "PATH=$PATH" "TERM=${TERM:-dumb}"
    "LANG=${LANG:-C}" "SHELLFISH_CONFIG_DIR=$config_dir"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture" "SHELLFISH_SESSION=$session"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY" "TMPDIR=$tool_directory" "TMPPREFIX=$tool_directory/zsh"
  )
  [[ -z ${LC_ALL-} ]] || environment+=( "LC_ALL=$LC_ALL" )
  [[ -z ${LC_CTYPE-} ]] || environment+=( "LC_CTYPE=$LC_CTYPE" )
  [[ -z ${XDG_CONFIG_HOME-} ]] || environment+=( "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" )
  environment+=( "${SF_ENVIRONMENT_VALUES[@]}" )
  names=( ${=SF_RUN[env_names]} )
  arguments=()
  for selected in $names; do arguments+=( -u "$selected" ); done
  arguments+=( "${environment[@]}" "$command" )
  if [[ $sandbox == true ]]; then
    arguments=( -i "${arguments[@]:$(( ${#names} * 2 ))}" )
    sandbox_arguments=( --monitor --fence-log-file "$capture/sandbox.log"
      --settings "$settings" --expose-host-path "$command" --expose-host-path-rw "$tool_directory"
      --expose-host-path-rw "$capture/control" )
    for expose in ${(f)read_paths}; do
      sandbox_arguments+=( --expose-host-path "$expose" )
    done
    for expose in ${(f)write_paths}; do
      sandbox_arguments+=( --expose-host-path-rw "$expose" )
    done
    process_command=( "$fence" "${sandbox_arguments[@]}" -- /usr/bin/env "${arguments[@]}" )
  else
    process_command=( /usr/bin/env "${arguments[@]}" )
  fi
  if ! sf_process_run "$capture" "${cwd:A}" "${stdin:A}" "$max_capture" \
      "${process_command[@]}"; then
    SF_RUN_TOOL_ERROR=$SF_PROCESS_ERROR
    return 1
  fi
  process=( "${reply[@]}" )
  if (( process[2] )); then
    return $process[1]
  fi
  control_bytes=$process[5]
  (( control_bytes <= max_capture )) || {
    SF_RUN_TOOL_ERROR='tool control data exceeds capture limit'
    return 1
  }
  budget=$(( max_capture - control_bytes ))
  bounded_stderr="$capture/stderr.bounded"
  bounded_stdout="$capture/stdout.bounded"
  sf_run_tool_bound "$capture/stderr" "$bounded_stderr" $budget || return 1
  stderr_bytes=$(wc -c <"$bounded_stderr") || return 1
  sf_run_tool_bound "$capture/stdout" "$bounded_stdout" $(( budget - stderr_bytes )) || return 1
  if (( process[1] )) && grep -qs $'✗' "$capture/sandbox.log"; then denied=1; fi
  REPLY=$(sf_jq -cn --rawfile stdout "$bounded_stdout" --rawfile stderr "$bounded_stderr" \
    --slurpfile control "$capture/control" --argjson control_bytes "$control_bytes" \
    --argjson exit_code "$process[1]" --argjson denied "$denied" '
      include "lib/session";
      (if $control_bytes == 0 then {}
       elif ($control | length) == 1 and ($control[0] | type) == "object" then $control[0]
       else error("invalid control") end) as $control |
      if ($control | if has("state") then
          .state | type == "array" and all(.[];
            type == "object" and keys == ["name", "value"] and
            ({type:"state"} + . | canonical_state))
        else true end) and (($control | del(.state)) == {})
      then
        {output:{stdout:$stdout,stderr:$stderr,exit_code:$exit_code},
         states:[$control.state[]? | {type:"state"} + .]} +
        (if $denied == 1 then {sandbox_denied:true} else {} end)
      else error("invalid control") end
    ' 2>/dev/null) || { SF_RUN_TOOL_ERROR='tool returned invalid control data'; return 1; }
  } always {
    rm -rf -- "$capture"
  }
}

sf_run_tool_complete() {
  local tool_request=$1 id=$2 name=$3 input=$4 executable=$5 render=$6 outcome=$7 projection
  local -a fields states
  projection=$(sf_jq -jrn --argjson request "$tool_request" --arg id "$id" --arg name "$name" \
    --argjson input "$input" --arg executable "$executable" --argjson render "$render" \
    --argjson outcome "$outcome" '
      include "lib/session";
      include "lib/runtime";
      def field: ., "\u0000";
      render_component($render;$name;$input;
        ($outcome.output + if $outcome | has("reason") then {stderr:$outcome.reason} else {} end)) as $rendered |
      (if $outcome.sandbox_denied then
        "\n\n<sandbox_notice>A denial was detected during this tool call. " +
        "This does not necessarily mean the tool failed.</sandbox_notice>"
      else "" end) as $notice |
      ({type:"tool_result",id:$id,name:$name,input:$input,exit_code:$outcome.output.exit_code} +
       (if $executable == "" then {} else {executable:$executable} end) +
       (if $rendered.user_text == null then {} else {user_text:$rendered.user_text} end) +
       (if $rendered.model_text == null then {} else {model_text:($rendered.model_text + $notice)} end)) as $result |
      if $result | canonical_tool_result then
        ($request + {tool_response:$outcome.output} | tojson | field),
        ($result | tojson | field), ($outcome.states | length | tostring | field),
        ($outcome.states[] | tojson | field), ("ok" | field)
      else error("invalid result") end
    ' 2>/dev/null) || { SF_RUN_TOOL_ERROR="cannot finish tool result: $name"; return 1; }
  fields=( "${(@0)${projection%$'\0'}}" )
  [[ $fields[-1] == ok && $fields[3] == <-> ]] &&
    (( ${#fields} == fields[3] + 4 )) || {
      SF_RUN_TOOL_ERROR="cannot finish tool result: $name"
      return 1
    }
  REPLY=$fields[2]
  reply=( "$fields[1]" "${(@)fields[4,-2]}" )
}
