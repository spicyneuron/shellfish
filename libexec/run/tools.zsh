emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_prepare] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -g SF_RUN_TOOL_ERROR=''

sf_run_tools_schema() {
  local runtime=$1
  REPLY=$(jq -cn --argjson runtime "$runtime" '
    $runtime.harness as $harness |
    [$harness.tools[] |
      .manifest as $manifest |
      (($harness.sandbox and $manifest.sandbox and
        ($manifest.allow_sandbox_bypass // false))) as $bypass |
      {name,description:($manifest.description +
        if $harness.sandbox and $manifest.sandbox
        then "\n\nThis tool runs under its package sandbox policy."
        else "\n\nSandboxing is disabled; this tool runs with the current user permissions." end +
        if .name == "shell" and $bypass
        then "\n\nWhen requesting an unsandboxed command, keep it to one logical operation. Split multi-step or compound commands across calls so each approval is easy to review."
        else "" end),
       input_schema:($manifest.input_schema |
         if $bypass then
           .properties.request_sandbox_bypass={type:"boolean",description:"Request approval to run without the sandbox"} |
           .properties.sandbox_bypass_reason={type:"string",minLength:1,
             description:"Explain why this tool call must run outside the sandbox"} |
           .allOf=((.allOf // []) + [{
             if:{properties:{request_sandbox_bypass:{const:true}},required:["request_sandbox_bypass"]},
             then:{required:["sandbox_bypass_reason"]}}])
         else . end)}]
  ' 2>/dev/null) || { SF_RUN_TOOL_ERROR='cannot inspect configured tools'; return 1; }
}

sf_run_tool_component() {
  local runtime=$1 name=$2
  REPLY=$(jq -c --arg name "$name" '[.harness.tools[] | select(.name == $name)][0] // empty' \
    <<<"$runtime") || return 1
}

sf_run_tool_render() {
  local component=$1 name=$2 input=$3 output=$4
  local render='{"initial_user_text":"${name}\n${input}","user_text":"${name}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}","model_text":"${output.stdout}${output.stderr}\nexit ${output.exit_code}","permission_user_text":"${input}"}'
  [[ -z $component ]] || render=$(jq -c '.manifest.render' <<<"$component") || return
  REPLY=$(sf_jq -cn --argjson render "$render" --arg name "$name" \
    --argjson input "$input" --argjson output "$output" '
      include "lib/render";
      render_component($render;$name;$input;$output)
    ' 2>/dev/null)
}

sf_run_tool_activity() {
  local id=$1 name=$2 input=$3 component=$4 rendered
  sf_run_tool_render "$component" "$name" "$input" \
    '{"stdout":"","stderr":"","exit_code":0}' || return
  rendered=$REPLY
  REPLY=$(jq -cn --arg id "$id" --arg name "$name" --argjson input "$input" \
    --argjson rendered "$rendered" '
      {type:"_tool_activity",id:$id,name:$name,input:$input} +
      (if $rendered.initial_user_text == null then {} else {user_text:$rendered.initial_user_text} end)
    ')
}

sf_run_tool_refused() {
  local reason=$1
  integer exit_code=$2
  REPLY=$(jq -cn --arg reason "$reason" --argjson exit_code "$exit_code" \
    '{output:{stdout:"",stderr:"",exit_code:$exit_code},states:[],reason:$reason}')
}

sf_run_tool_permission() {
  local runtime=$1 component=$2 input=$3
  REPLY=$(jq -cn --argjson runtime "$runtime" --argjson component "${component:-null}" \
    --argjson input "$input" '
      if $component == null or ($runtime.harness.sandbox | not) then {decision:"none"}
      elif (($input.request_sandbox_bypass // false) | type) != "boolean" then
        {decision:"deny",reason:"sandbox bypass is not allowed"}
      elif ($input.request_sandbox_bypass // false) == false then {decision:"none"}
      elif ($component.manifest.allow_sandbox_bypass // false) != true then
        {decision:"deny",reason:"sandbox bypass is not allowed"}
      elif ($input.sandbox_bypass_reason? | type) != "string" or
          $input.sandbox_bypass_reason == "" then
        {decision:"failure",reason:"sandbox bypass reason is required"}
      else {decision:"request",reason:$input.sandbox_bypass_reason} end
    ' 2>/dev/null) || { SF_RUN_TOOL_ERROR='cannot inspect tool permission'; return 1; }
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

# Return remaining control in REPLY and canonical state records in reply.
sf_run_control_decode() {
  local capture=$1 control output
  REPLY=''
  reply=()

  control=$(jq -cse '
    if length == 1 and (.[0] | type == "object") then .[0]
    else error("expected one object") end
  ' "$capture" 2>/dev/null) || {
    REPLY=malformed
    return 1
  }
  output=$(sf_jq -jnre --argjson control "$control" '
    include "lib/session/read";
    def field: ., "\u0000";
    if $control | if has("state") then
        .state | type == "array" and all(.[];
          type == "object" and keys == ["name", "value"] and
          ({type:"state"} + . | canonical_state))
      else true end
    then
      ($control |
        if has("state") then
          del(.state) | if length == 0 then "" else tojson end
        else tojson end | field),
      ($control.state[]? | {type:"state"} + . | tojson | field)
    else error("invalid state control") end
  ' 2>/dev/null) || {
    REPLY=state
    return 1
  }
  reply=( "${(@0)${output%$'\0'}}" )
}

sf_run_tool_execute() {
  setopt local_options no_err_exit
  local session=$1 runtime=$2 component=$3 input=$4 tool_directory
  local command selected settings cwd fence capture stdin
  local bounded_stdout bounded_stderr output
  local config_dir='' env_file execution_input state_projection=''
  local -a arguments environment names states process_command process
  integer max_capture control_bytes budget stderr_bytes denied=0

  tool_directory=$5
  SF_RUN_TOOL_ERROR=''
  command=$(jq -r '.command' <<<"$component") || return 1
  selected=$(jq -r '(.manifest.environment // []) | join(" ")' <<<"$component") || return 1
  settings=$(jq -r '.settings // ""' <<<"$component") || return 1
  max_capture=$(jq -r '.harness.max_capture_bytes' <<<"$runtime") || return 1
  cwd=$SF_SESSION[cwd]
  fence=$(jq -r '.harness.fence' <<<"$runtime") || return 1
  env_file=$(jq -r '.backend.env_file' <<<"$runtime") || return 1
  [[ -z $env_file ]] || config_dir=${env_file:h}
  execution_input=$(jq -c 'del(.request_sandbox_bypass,.sandbox_bypass_reason)' <<<"$input") || return 1
  sf_environment_prepare "$runtime" "$selected" || {
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
  names=( $SF_ENVIRONMENT_NAMES )
  arguments=()
  for selected in $names; do arguments+=( -u "$selected" ); done
  arguments+=( "${environment[@]}" "$command" )
  if jq -e '.harness.sandbox' <<<"$runtime" >/dev/null &&
      jq -e '.manifest.sandbox' <<<"$component" >/dev/null &&
      [[ $(jq -r '.request_sandbox_bypass // false' <<<"$input") != true ]]; then
    arguments=( -i "${arguments[@]:$(( ${#names} * 2 ))}" )
    local -a sandbox_arguments=( --monitor --fence-log-file "$capture/sandbox.log"
      --settings "$settings" --expose-host-path "$command" --expose-host-path-rw "$tool_directory"
      --expose-host-path-rw "$capture/control" )
    local expose
    for expose in ${(f)$(jq -r '.harness.sandbox_read_paths[]' <<<"$runtime")}; do
      sandbox_arguments+=( --expose-host-path "$expose" )
    done
    for expose in ${(f)$(jq -r '.harness.sandbox_write_paths[]' <<<"$runtime")}; do
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
  states=()
  if (( control_bytes )); then
    sf_run_control_decode "$capture/control" || {
      SF_RUN_TOOL_ERROR='tool returned invalid control data'
      return 1
    }
    [[ -z $reply[1] ]] || {
      SF_RUN_TOOL_ERROR='tool returned invalid control data'
      return 1
    }
    (( ${#reply} <= 1 )) || states=( "${(@)reply[2,-1]}" )
  fi
  budget=$(( max_capture - control_bytes ))
  bounded_stderr="$capture/stderr.bounded"
  bounded_stdout="$capture/stdout.bounded"
  sf_run_tool_bound "$capture/stderr" "$bounded_stderr" $budget || return 1
  stderr_bytes=$(wc -c <"$bounded_stderr") || return 1
  sf_run_tool_bound "$capture/stdout" "$bounded_stdout" $(( budget - stderr_bytes )) || return 1
  output=$(jq -cn --rawfile stdout "$bounded_stdout" --rawfile stderr "$bounded_stderr" \
    --argjson exit_code "$process[1]" \
    '{stdout:$stdout,stderr:$stderr,exit_code:$exit_code}') || return 1
  state_projection=$(printf '%s\n' "${states[@]}" | jq -sc '.') || return 1
  # fence marks each monitored violation with a cross in its log. Report one only
  # alongside a failing tool, since a successful run tolerated whatever was blocked.
  if (( process[1] )) && grep -qs $'✗' "$capture/sandbox.log"; then denied=1; fi
  REPLY=$(jq -cn --argjson output "$output" --argjson states "$state_projection" \
    --argjson denied "$denied" \
    '{output:$output,states:$states} +
     (if $denied == 1 then {sandbox_denied:true} else {} end)') || return 1
  } always {
    rm -rf -- "$capture"
  }
}

sf_run_tool_record() {
  local id=$1 name=$2 input=$3 component=$4 outcome=$5 rendered executable='' render_output
  [[ -z $component ]] || executable=$(jq -r '.command' <<<"$component") || return
  render_output=$(jq -c '.output + if has("reason") then {stderr:.reason} else {} end' \
    <<<"$outcome") || return
  sf_run_tool_render "$component" "$name" "$input" "$render_output" || return
  rendered=$REPLY
  REPLY=$(sf_jq -cn --arg id "$id" --arg name "$name" --argjson input "$input" \
    --arg executable "$executable" --argjson outcome "$outcome" \
    --argjson rendered "$rendered" '
      include "lib/session/read";
      (if $outcome.sandbox_denied then
        "\n\n<sandbox_notice>A denial was detected during this tool call. " +
        "This does not necessarily mean the tool failed.</sandbox_notice>"
      else "" end) as $notice |
      ({type:"tool_result",id:$id,name:$name,input:$input,exit_code:$outcome.output.exit_code} +
       (if $executable == "" then {} else {executable:$executable} end) +
       (if $rendered.user_text == null then {} else {user_text:$rendered.user_text} end) +
       (if $rendered.model_text == null then {} else {model_text:($rendered.model_text + $notice)} end)) as $result |
      if $result | canonical_tool_result then $result else error("invalid result") end
    ' 2>/dev/null) || { SF_RUN_TOOL_ERROR="cannot render tool result: $name"; return 1; }
}
