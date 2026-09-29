emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_run_component_execute] )) || source "$SF_ROOT/libexec/run/component.zsh"

typeset -g SF_RUN_TOOL_ERROR=''

# Everything execution and settlement need for one call.
typeset -gA SF_TOOL_PLAN=()

sf_run_tool_plan() {
  local call=$1
  sf_jq_fields -rn --argjson profile "$SF_RUN[profile]" --argjson tools "$SF_RUN[tools]" \
    --argjson call "$call" --argjson turn "$SF_RUN[turn_id]" '
      include "lib/fields";
      include "lib/profile";
      include "lib/session";
      include "libexec/run/component";
      $call.id as $id | $call.name as $name | $call.input as $input |
      [$tools[] | select(.name == $name)][0] as $tool |
      ($tool.manifest // {}) as $manifest |
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
      ($profile.sandbox and ($manifest.sandbox // false) and
        (($input.request_sandbox_bypass // false) | not)) as $sandboxed |
      entry("id"; $id), entry("name"; $name), entry("input"; $input | tojson),
      entry("request";
        {turn_id:$turn,tool_name:$name,tool_use_id:$id,tool_input:$input} | tojson),
      entry("component"; component_plan(
        (if $sandboxed then $manifest else
          $manifest |
          .user_text=(.user_text_unsandboxed // .user_text) |
          .user_text_done=(.user_text_done_unsandboxed // .user_text_done)
        end);
        {user_text:"${name} ${input}",
         user_text_done:"${name} ${input}\n${output.stdout}${output.stderr}",
         user_text_skipped:"${name} ${input}\n${output.stderr}",
         model_text:"${output.stdout}${output.stderr}"}; $name; $input;
        {type:"_draft",id:$id,name:$name}) | tojson),
      entry("decision"; $permission.decision),
      entry("permission_reason"; $permission.reason // ""),
      entry("permission_preview";
        render_template($manifest.user_permission // "${input}"; $name; $input; {}; {})),
      entry("executable"; $tool.command // ""),
      entry("environment"; ($tool.manifest.environment // []) | join(" ")),
      entry("profile_env"; $profile.env | tojson),
      entry("max_capture"; $manifest.max_capture_bytes // $profile.max_capture_bytes | tostring),
      entry("execution_input";
        $input | del(.request_sandbox_bypass,.sandbox_bypass_reason) | tojson),
      entry("sandbox"; $sandboxed | tostring),
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

sf_run_tool_execute() {
  setopt local_options no_err_exit
  local session=$1 command=$SF_TOOL_PLAN[executable]
  local selected=$SF_TOOL_PLAN[environment]
  local config_dir
  local execution_input=$SF_TOOL_PLAN[execution_input] sandbox=$SF_TOOL_PLAN[sandbox]
  local read_paths=$SF_TOOL_PLAN[read_paths] write_paths=$SF_TOOL_PLAN[write_paths]
  local cwd=$SF_RUN[cwd] capture stdin
  local expose darwin_temp='' temp_dir=${TMPDIR:-/tmp}
  local -a arguments process_command sandbox_arguments temp_paths
  integer max_capture=$SF_TOOL_PLAN[max_capture]

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
  sf_run_component_begin "$session" "$SF_TOOL_PLAN[component]" || {
    SF_RUN_TOOL_ERROR='cannot emit tool draft'
    return 1
  }
  sf_run_component_execute "$capture" "${cwd:A}" "${stdin:A}" "$max_capture" \
    "${process_command[@]}" || { SF_RUN_TOOL_ERROR=$REPLY; return 1; }
  case $reply[1] in
    (interrupted) return $reply[2] ;;
    (invalid) SF_RUN_TOOL_ERROR='tool returned invalid control data'; return 1 ;;
    (overflow) sf_run_tool_refused 'tool result exceeds capture limit' 1 true; return ;;
  esac
  if (( reply[2] )) && grep -qs $'✗' "$capture/sandbox.log"; then
    REPLY=$(jq -c '.output.stderr += "\n<sandbox_notice>A denial was detected during this tool call. This does not necessarily mean the tool failed.</sandbox_notice>"' <<<"$REPLY") ||
      { SF_RUN_TOOL_ERROR='cannot decode tool result'; return 1; }
  fi
  } always {
    rm -rf -- "$capture"
    rm -f -- "$stdin"
  }
}

sf_run_tool_complete() {
  sf_jq_fields -cn --argjson component "$1" --argjson outcome "$2" \
    --argjson request "$SF_TOOL_PLAN[request]" '
    include "lib/fields";
    include "lib/session";
    include "lib/profile";
    include "libexec/run/component";
    {type:"tool_result",id:$request.tool_use_id,name:$request.tool_name,
     input:$request.tool_input,exit_code:$outcome.output.exit_code} +
      component_texts($component; $outcome) |
    if canonical_tool_result then entry("result"; tojson),
      entry("post_request"; $request + {tool_response:$outcome.output} | tojson), ("ok" | field)
    else error("invalid tool result") end
  ' || { SF_RUN_TOOL_ERROR="cannot finish tool result: $SF_TOOL_PLAN[name]"; return 1; }
}
