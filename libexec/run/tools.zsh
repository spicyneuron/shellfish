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
      render_template($tool.manifest.user_draft // "${name} ${input}"; $name; $input) as $draft |
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
      entry("event"; {type:"_draft",id:$id,name:$name,user_text:$draft} | tojson),
      entry("decision"; $permission.decision),
      entry("permission_reason"; $permission.reason // ""),
      entry("permission_preview";
        render_template($tool.manifest.user_permission // "${input}"; $name; $input)),
      entry("executable"; $tool.command // ""),
      entry("environment"; ($tool.manifest.environment // []) | join(" ")),
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
  local reason=$1
  integer exit_code=$2
  REPLY=$(jq -cn --arg reason "$reason" --argjson exit_code "$exit_code" \
    '{output:{stdout:"",stderr:$reason,exit_code:$exit_code},states:[]}')
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

# Apply one tool fd 3 line as it arrives. Drafts stream at once; state and the
# last final wait for a completed exit.
sf_run_tool_line() {
  local -A line
  [[ -z $SF_TOOL_RESULT[error] ]] || return 0
  sf_run_component_line "$1" '' "$SF_TOOL_PLAN[event]" '{}' \
    "$SF_TOOL_RESULT[preview]" || { SF_TOOL_RESULT[error]=invalid; return 1; }
  line=( "${reply[@]}" )
  [[ $line[valid] == true ]] || { SF_TOOL_RESULT[error]=invalid; return 1; }
  SF_TOOL_RESULT[states]+=${line[states]:+$line[states]$'\n'}
  SF_TOOL_RESULT[preview]=$line[preview]
  [[ -z $line[texts] ]] || SF_TOOL_RESULT[final]=$line[texts]
  [[ -z $line[draft] ]] || sf_run_emit "$line[draft]" ||
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
  integer max_capture=$SF_TOOL_PLAN[max_capture] stderr_bytes denied=0

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
    "SHELLFISH_EXECUTABLE=$SF_ENTRY" "SHELLFISH_DEFAULT_DIR=$SF_SHARE/profiles/default"
  )
  [[ -z ${LC_ALL-} ]] || arguments+=( "LC_ALL=$LC_ALL" )
  [[ -z ${LC_CTYPE-} ]] || arguments+=( "LC_CTYPE=$LC_CTYPE" )
  [[ -z ${XDG_CONFIG_HOME-} ]] || arguments+=( "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" )
  arguments+=( "${SF_ENVIRONMENT_VALUES[@]}" )
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
  SF_TOOL_RESULT=( error '' states '' preview null final '' )
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
    sf_run_tool_refused 'tool result exceeds capture limit' 1
    return
  fi
  bounded_stderr="$capture/stderr.bounded"
  bounded_stdout="$capture/stdout.bounded"
  sf_run_tool_bound "$capture/stderr" "$bounded_stderr" $max_capture || return 1
  stderr_bytes=$(wc -c <"$bounded_stderr") || return 1
  sf_run_tool_bound "$capture/stdout" "$bounded_stdout" $(( max_capture - stderr_bytes )) || return 1
  if (( process[exit_code] )) && grep -qs $'✗' "$capture/sandbox.log"; then denied=1; fi
  REPLY=$(sf_jq -cn --rawfile stdout "$bounded_stdout" --rawfile stderr "$bounded_stderr" \
    --argjson exit_code "$process[exit_code]" --argjson denied "$denied" \
    --arg states "$SF_TOOL_RESULT[states]" --arg final "$SF_TOOL_RESULT[final]" \
    --argjson preview "$SF_TOOL_RESULT[preview]" '
      {output:{stdout:$stdout,stderr:$stderr,exit_code:$exit_code},
       states:[$states | split("\n")[] | select(. != "") | fromjson]} +
      (if $final == "" then {} else {final:($final | fromjson)} end) +
      (if $preview == null then {} else {preview:$preview} end) +
      (if $denied == 1 then {sandbox_denied:true} else {} end)
    ') || { SF_RUN_TOOL_ERROR='cannot decode tool result'; return 1; }
  } always {
    rm -rf -- "$capture"
    rm -f -- "$stdin"
  }
}

# Without a final, the user sees the draft followed by stdout and stderr, and
# the model sees stdout and stderr.
sf_run_tool_complete() {
  local outcome=$1 name=$SF_TOOL_PLAN[name]
  sf_jq_fields -rn --argjson request "$SF_TOOL_PLAN[request]" \
    --arg id "$SF_TOOL_PLAN[id]" --arg name "$name" --arg draft "$SF_TOOL_PLAN[draft]" \
    --argjson input "$SF_TOOL_PLAN[input]" --argjson outcome "$outcome" '
      include "lib/fields";
      include "lib/session";
      ($outcome.final // (
        ($outcome.output.stdout + $outcome.output.stderr) as $output |
        ([$draft, $output] | map(select(. != "")) | join("\n")) as $user |
        (if $user == "" then {} else {user_text:$user} end) +
        (if $output == "" then {} else {model_text:$output} end) +
        (if $outcome | has("preview") then {user_preview_lines:$outcome.preview} else {} end)
      )) as $texts |
      ({type:"tool_result",id:$id,name:$name,input:$input,exit_code:$outcome.output.exit_code} +
       $texts |
       if $outcome.sandbox_denied and has("model_text") then
         .model_text += "\n\n<sandbox_notice>A denial was detected during this tool call. " +
           "This does not necessarily mean the tool failed.</sandbox_notice>"
       else . end) as $result |
      if $result | canonical_tool_result then
        entry("post_request"; $request + {tool_response:$outcome.output} | tojson),
        entry("result"; $result | tojson),
        entry("states"; [$outcome.states[] | tojson] | join("\n")),
        ("ok" | field)
      else error("invalid result") end
    ' || { SF_RUN_TOOL_ERROR="cannot finish tool result: $name"; return 1; }
}
