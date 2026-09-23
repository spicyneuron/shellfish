emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_RUN_TOOL_ERROR=''

# Everything execution and settlement need for one call, keyed by name.
typeset -gA SF_TOOL_PLAN=()

sf_run_tool_plan() {
  local runtime=$1 call=$2
  sf_jq_fields -rn --argjson runtime "$runtime" --argjson call "$call" \
    --argjson turn "$SF_RUN[turn_id]" '
      include "lib/fields";
      include "lib/runtime";
      $call.id as $id | $call.name as $name | $call.input as $input |
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
      entry("id"; $id), entry("name"; $name), entry("input"; $input | tojson),
      entry("request";
        {turn_id:$turn,tool_name:$name,tool_use_id:$id,tool_input:$input} | tojson),
      entry("activity";
        {type:"_tool_activity",id:$id,name:$name,input:$input} +
        (if $rendered.initial_user_text == null then {}
         else {user_text:$rendered.initial_user_text} end) | tojson),
      entry("decision"; $permission.decision),
      entry("permission_reason"; $permission.reason // ""),
      entry("permission_preview"; $rendered.permission_user_text // ""),
      entry("executable"; $tool.command // ""),
      entry("environment"; ($tool.manifest.environment // []) | join(" ")),
      entry("settings"; $tool.settings // ""),
      entry("max_capture"; $runtime.harness.max_capture_bytes | tostring),
      entry("execution_input";
        $input | del(.request_sandbox_bypass,.sandbox_bypass_reason) | tojson),
      entry("sandbox"; $runtime.harness.sandbox and ($tool.manifest.sandbox // false) and
        (($input.request_sandbox_bypass // false) | not) | tostring),
      entry("read_paths"; $runtime.harness.sandbox_read_paths | join("\n")),
      entry("write_paths"; $runtime.harness.sandbox_write_paths | join("\n")),
      entry("render"; $render | tojson),
      ("ok" | field)
    ' || { SF_RUN_TOOL_ERROR='cannot inspect tool'; return 1; }
  SF_TOOL_PLAN=( "${reply[@]}" )
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

# Collect fd 3 lines for sf_run_tool_execute.
sf_run_tool_control() {
  controls+=( "$1" )
}

sf_run_tool_execute() {
  setopt local_options no_err_exit
  local session=$1 command=$SF_TOOL_PLAN[executable]
  local selected=$SF_TOOL_PLAN[environment] settings=$SF_TOOL_PLAN[settings]
  local config_dir
  local execution_input=$SF_TOOL_PLAN[execution_input] sandbox=$SF_TOOL_PLAN[sandbox]
  local read_paths=$SF_TOOL_PLAN[read_paths] write_paths=$SF_TOOL_PLAN[write_paths]
  local cwd=$SF_RUN[cwd] capture stdin bounded_stdout bounded_stderr
  local expose darwin_temp='' temp_dir=${TMPDIR:-/tmp}
  local -a arguments process_command sandbox_arguments temp_paths controls=()
  local -A process
  integer max_capture=$SF_TOOL_PLAN[max_capture] control_bytes budget stderr_bytes denied=0

  SF_RUN_TOOL_ERROR=''
  [[ $sandbox != true || -n ${commands[fence]-} ]] ||
    { SF_RUN_TOOL_ERROR='sandboxing requires fence'; return 1; }
  sf_environment_load "$selected" || {
    SF_RUN_TOOL_ERROR=$SF_ENVIRONMENT_ERROR
    return 1
  }
  config_dir=$REPLY
  [[ -d $temp_dir ]] || { SF_RUN_TOOL_ERROR='temporary directory is unavailable'; return 1; }
  temp_dir=${temp_dir:A}
  if [[ $OSTYPE == darwin* && -x /usr/bin/getconf ]]; then
    darwin_temp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || darwin_temp=''
    if [[ -d $darwin_temp ]]; then
      darwin_temp=${darwin_temp:A}
    else
      darwin_temp=''
    fi
  fi
  sf_scratch_file tool-input || { SF_RUN_TOOL_ERROR='cannot prepare tool input'; return 1; }
  stdin=$REPLY
  print -r -- "$execution_input" >"$stdin" || {
    rm -f -- "$stdin"
    SF_RUN_TOOL_ERROR='cannot prepare tool input'
    return 1
  }
  sf_scratch_directory tool || {
    rm -f -- "$stdin"
    SF_RUN_TOOL_ERROR='cannot prepare tool capture'
    return 1
  }
  capture=$REPLY
  {
  arguments=(
    "HOME=${HOME:-$cwd}" "PATH=$PATH" "TERM=${TERM:-dumb}"
    "LANG=${LANG:-C}" "SHELLFISH_CONFIG_DIR=$config_dir"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture" "SHELLFISH_SESSION=$session"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY"
  )
  [[ -z ${LC_ALL-} ]] || arguments+=( "LC_ALL=$LC_ALL" )
  [[ -z ${LC_CTYPE-} ]] || arguments+=( "LC_CTYPE=$LC_CTYPE" )
  [[ -z ${XDG_CONFIG_HOME-} ]] || arguments+=( "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" )
  arguments+=( "${SF_ENVIRONMENT_VALUES[@]}" )
  arguments+=( "TMPDIR=$temp_dir" "TMPPREFIX=$temp_dir/zsh" "$command" )
  if [[ $sandbox == true ]]; then
    arguments=( -i "${arguments[@]}" )
    sandbox_arguments=( --monitor --fence-log-file "$capture/sandbox.log"
      --settings "$settings" --expose-host-path "$command" )
    temp_paths=( /tmp "$temp_dir" )
    [[ -z $darwin_temp ]] || temp_paths+=( "$darwin_temp" )
    for expose in ${(u)temp_paths}; do
      [[ -d $expose ]] && sandbox_arguments+=( --expose-host-path-rw "$expose" )
    done
    for expose in ${(f)read_paths}; do
      sandbox_arguments+=( --expose-host-path "$expose" )
    done
    for expose in ${(f)write_paths}; do
      sandbox_arguments+=( --expose-host-path-rw "$expose" )
    done
    process_command=( "$commands[fence]" "${sandbox_arguments[@]}" -- /usr/bin/env "${arguments[@]}" )
  else
    process_command=( /usr/bin/env "${arguments[@]}" )
  fi
  if ! sf_process_run "$capture" "${cwd:A}" "${stdin:A}" "$max_capture" \
      sf_run_tool_control "${process_command[@]}"; then
    SF_RUN_TOOL_ERROR=$SF_PROCESS_ERROR
    return 1
  fi
  process=( "${reply[@]}" )
  if (( process[interrupted] )); then
    return $process[exit_code]
  fi
  control_bytes=$process[control_bytes]
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
  if (( process[exit_code] )) && grep -qs $'✗' "$capture/sandbox.log"; then denied=1; fi
  REPLY=$(sf_jq -cn --rawfile stdout "$bounded_stdout" --rawfile stderr "$bounded_stderr" \
    --argjson exit_code "$process[exit_code]" --argjson denied "$denied" '
      include "lib/session";
      ($ARGS.positional | map(fromjson)) as $control |
      (if ($control | length) == 0 then {}
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
    ' --args "${controls[@]}" 2>/dev/null) || { SF_RUN_TOOL_ERROR='tool returned invalid control data'; return 1; }
  } always {
    rm -rf -- "$capture"
    rm -f -- "$stdin"
  }
}

sf_run_tool_complete() {
  local outcome=$1 name=$SF_TOOL_PLAN[name]
  sf_jq_fields -rn --argjson request "$SF_TOOL_PLAN[request]" \
    --arg id "$SF_TOOL_PLAN[id]" --arg name "$name" \
    --argjson input "$SF_TOOL_PLAN[input]" \
    --argjson render "$SF_TOOL_PLAN[render]" --argjson outcome "$outcome" '
      include "lib/fields";
      include "lib/session";
      include "lib/runtime";
      render_component($render;$name;$input;
        ($outcome.output + if $outcome | has("reason") then {stderr:$outcome.reason} else {} end)) as $rendered |
      (if $outcome.sandbox_denied then
        "\n\n<sandbox_notice>A denial was detected during this tool call. " +
        "This does not necessarily mean the tool failed.</sandbox_notice>"
      else "" end) as $notice |
      ({type:"tool_result",id:$id,name:$name,input:$input,exit_code:$outcome.output.exit_code} +
       (if $rendered.user_text == null then {} else {user_text:$rendered.user_text} end) +
       (if $rendered.model_text == null then {} else {model_text:($rendered.model_text + $notice)} end)) as $result |
      if $result | canonical_tool_result then
        entry("post_request"; $request + {tool_response:$outcome.output} | tojson),
        entry("result"; $result | tojson),
        entry("states"; [$outcome.states[] | tojson] | join("\n")),
        ("ok" | field)
      else error("invalid result") end
    ' || { SF_RUN_TOOL_ERROR="cannot finish tool result: $name"; return 1; }
}
