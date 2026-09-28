emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_RUN_TOOL_ERROR=''

# Everything execution and settlement need for one call, and what the running
# tool has written to fd 3, both keyed by name.
typeset -gA SF_TOOL_PLAN=() SF_TOOL_RESULT=()

sf_run_tool_plan() {
  local call=$1
  sf_jq_fields -rn --argjson profile "$SF_RUN[profile]" --argjson tools "$SF_RUN[tools]" \
    --argjson call "$call" --argjson turn "$SF_RUN[turn_id]" '
      include "lib/fields";
      include "lib/profile";
      $call.id as $id | $call.name as $name | $call.input as $input |
      [$tools[] | select(.name == $name)][0] as $tool |
      ($tool.manifest // {}) as $manifest |
      {user_text:($manifest.user_text // "${name} ${input}"),
       user_text_done:($manifest.user_text_done // "${name} ${input}\n${output.stdout}${output.stderr}"),
       user_text_skipped:($manifest.user_text_skipped // "${name} ${input}\n${output.stderr}"),
       model_text:($manifest.model_text // "${output.stdout}${output.stderr}")} as $templates |
      render_template($templates.user_text; $name; $input; {}; {}) as $draft |
      (if $tool == null or ($profile.sandbox | not) then {decision:"none"}
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
      entry("draft"; $draft),
      entry("templates"; $templates | tojson),
      entry("fields"; ($manifest.input_schema.properties // {} | keys | map("input." + .)) | tojson),
      entry("preview"; $manifest.user_preview_lines // null | tojson),
      entry("event"; {type:"_draft",id:$id,name:$name,user_text:$draft} +
        if $manifest.user_preview_lines == null then {} else
          {user_preview_lines:$manifest.user_preview_lines} end | tojson),
      entry("decision"; $permission.decision),
      entry("permission_reason"; $permission.reason // ""),
      entry("permission_preview";
        render_template($manifest.user_permission // "${input}"; $name; $input; {}; {})),
      entry("executable"; $tool.command // ""),
      entry("environment"; ($tool.manifest.environment // []) | join(" ")),
      entry("profile_env"; $profile.env | tojson),
      entry("max_capture"; $profile.max_capture_bytes | tostring),
      entry("execution_input";
        $input | del(.request_sandbox_bypass,.sandbox_bypass_reason) | tojson),
      entry("sandbox"; $profile.sandbox and ($tool.manifest.sandbox // false) and
        (($input.request_sandbox_bypass // false) | not) | tostring),
      entry("read_paths"; $profile.sandbox_read_paths | join("\n")),
      entry("write_paths"; $profile.sandbox_write_paths | join("\n")),
      ("ok" | field)
    ' || { SF_RUN_TOOL_ERROR='cannot inspect tool'; return 1; }
  SF_TOOL_PLAN=( "${reply[@]}" )
}

sf_run_tool_refused() {
  local reason=$1 ran=${3:-false}
  integer exit_code=$2
  REPLY=$(jq -cn --arg reason "$reason" --argjson ran "$ran" \
    --argjson exit_code "$exit_code" '
    {output:{stdout:"",stderr:$reason,exit_code:$exit_code},ran:$ran}
  ')
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

# Apply one tool fd 3 line as it arrives. The view waits for a completed exit.
sf_run_tool_line() {
  local record
  local -A line
  [[ -z $SF_TOOL_RESULT[error] ]] || return 0
  sf_jq_fields -cn --arg raw "$1" --argjson data "$SF_TOOL_RESULT[data]" \
    --argjson templates "$SF_TOOL_RESULT[templates]" \
    --argjson fields "$SF_TOOL_PLAN[fields]" \
    --argjson preview "$SF_TOOL_PLAN[preview]" \
    --arg name "$SF_TOOL_PLAN[name]" --argjson input "$SF_TOOL_PLAN[input]" \
    --arg id "$SF_TOOL_PLAN[id]" '
      include "lib/fields";
      include "lib/profile";
      include "libexec/run/component";
      ($raw | try fromjson catch null |
        component_update($fields; $data; $templates; $name; $input; $preview;
          {type:"_draft",id:$id,name:$name})) as $update |
      if $update == null then entry("valid"; "false")
      else
        entry("valid"; "true"),
        entry("states"; [$update.states[] | tojson] | join("\n")),
        entry("data"; $update.data | tojson),
        entry("templates"; $update.templates | tojson),
        entry("draft"; $update.draft | tojson)
      end,
      ("ok" | field)
    ' || { SF_TOOL_RESULT[error]=invalid; return 1; }
  line=( "${reply[@]}" )
  [[ $line[valid] == true ]] || { SF_TOOL_RESULT[error]=invalid; return 1; }
  for record in ${(f)line[states]}; do
    sf_run_append "$SF_TOOL_RESULT[session]" "$record" ||
      { SF_TOOL_RESULT[error]=$REPLY; return 1; }
  done
  SF_TOOL_RESULT+=( data "$line[data]" templates "$line[templates]" )
  sf_run_emit "$line[draft]" ||
    { SF_TOOL_RESULT[error]='cannot emit tool draft'; return 1; }
}

sf_run_tool_execute() {
  setopt local_options no_err_exit
  local session=$1 command=$SF_TOOL_PLAN[executable]
  local selected=$SF_TOOL_PLAN[environment]
  local config_dir
  local execution_input=$SF_TOOL_PLAN[execution_input] sandbox=$SF_TOOL_PLAN[sandbox]
  local read_paths=$SF_TOOL_PLAN[read_paths] write_paths=$SF_TOOL_PLAN[write_paths]
  local cwd=$SF_RUN[cwd] capture stdin bounded_stdout bounded_stderr
  local expose darwin_temp='' temp_dir=${TMPDIR:-/tmp}
  local -a arguments process_command sandbox_arguments temp_paths
  local -A process
  integer max_capture=$SF_TOOL_PLAN[max_capture] denied=0

  SF_RUN_TOOL_ERROR=''
  sf_environment_load "$selected" "$SF_TOOL_PLAN[profile_env]" || {
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
    "${SF_ENVIRONMENT_VALUES[@]}"
    "HOME=${HOME:-$cwd}" "PATH=$PATH" "TERM=${TERM:-dumb}"
    "LANG=${LANG:-C}" "SHELLFISH_CONFIG_DIR=$config_dir"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture" "SHELLFISH_SESSION=$session"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY" "SHELLFISH_SHARE_DIR=$SF_SHARE"
  )
  [[ -z ${LC_ALL-} ]] || arguments+=( "LC_ALL=$LC_ALL" )
  [[ -z ${LC_CTYPE-} ]] || arguments+=( "LC_CTYPE=$LC_CTYPE" )
  [[ -z ${XDG_CONFIG_HOME-} ]] || arguments+=( "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" )
  arguments+=( "TMPDIR=$temp_dir" "TMPPREFIX=$temp_dir/zsh" "$command" )
  if [[ $sandbox == true ]]; then
    arguments=( -i "${arguments[@]}" )
    sandbox_arguments=( --monitor --fence-log-file "$capture/sandbox.log"
      --settings "${command:h}/fence.jsonc" --expose-host-path "$command" )
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
  SF_TOOL_RESULT=( session "$session" error '' data '{}' templates "$SF_TOOL_PLAN[templates]" )
  if ! sf_process_run "$capture" "${cwd:A}" "${stdin:A}" "$max_capture" \
      sf_run_tool_line "${process_command[@]}"; then
    SF_RUN_TOOL_ERROR=$SF_PROCESS_ERROR
    return 1
  fi
  process=( "${reply[@]}" )
  if (( process[interrupted] )); then
    return $process[exit_code]
  fi
  if [[ $SF_TOOL_RESULT[error] == invalid ]]; then
    SF_RUN_TOOL_ERROR='tool returned invalid control data'
    return 1
  elif [[ -n $SF_TOOL_RESULT[error] ]]; then
    SF_RUN_TOOL_ERROR=$SF_TOOL_RESULT[error]
    return 1
  elif (( process[control_bytes] > max_capture )); then
    sf_run_tool_refused 'tool result exceeds capture limit' 1 true
    return
  fi
  bounded_stderr="$capture/stderr.bounded"
  bounded_stdout="$capture/stdout.bounded"
  sf_run_tool_bound "$capture/stderr" "$bounded_stderr" $max_capture || return 1
  sf_run_tool_bound "$capture/stdout" "$bounded_stdout" $max_capture || return 1
  if (( process[exit_code] )) && grep -qs $'✗' "$capture/sandbox.log"; then denied=1; fi
  REPLY=$(sf_jq -cn --rawfile stdout "$bounded_stdout" --rawfile stderr "$bounded_stderr" \
    --argjson exit_code "$process[exit_code]" --argjson denied "$denied" \
    --argjson data "$SF_TOOL_RESULT[data]" \
    --argjson templates "$SF_TOOL_RESULT[templates]" '
      {output:{stdout:$stdout,stderr:($stderr +
        if $denied == 1 then
          "\n<sandbox_notice>A denial was detected during this tool call. This does not necessarily mean the tool failed.</sandbox_notice>"
        else "" end),
        exit_code:$exit_code},data:$data,templates:$templates,ran:true}
    ') || { SF_RUN_TOOL_ERROR='cannot decode tool result'; return 1; }
  } always {
    rm -rf -- "$capture"
    rm -f -- "$stdin"
  }
}

sf_run_tool_complete() {
  local outcome=$1 name=$SF_TOOL_PLAN[name]
  sf_jq_fields -rn --argjson request "$SF_TOOL_PLAN[request]" \
    --arg id "$SF_TOOL_PLAN[id]" --arg name "$name" \
    --argjson templates "$SF_TOOL_PLAN[templates]" \
    --argjson preview "$SF_TOOL_PLAN[preview]" \
    --argjson input "$SF_TOOL_PLAN[input]" --argjson outcome "$outcome" '
      include "lib/fields";
      include "lib/session";
      include "lib/profile";
      include "libexec/run/component";
      ($outcome.templates // $templates) as $templates |
      ($outcome.data // {}) as $data |
      (component_render($templates; $outcome.ran; $name; $input; $outcome.output; $data;
        $preview)) as $texts |
      ({type:"tool_result",id:$id,name:$name,input:$input,exit_code:$outcome.output.exit_code} +
       $texts) as $result |
      if $result | canonical_tool_result then
        entry("post_request"; $request + {tool_response:$outcome.output} | tojson),
        entry("result"; $result | tojson),
        ("ok" | field)
      else error("invalid result") end
    ' || { SF_RUN_TOOL_ERROR="cannot finish tool result: $name"; return 1; }
}
