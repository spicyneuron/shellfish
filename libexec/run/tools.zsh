emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -g SF_TOOL_ERROR=''
typeset -g SF_TOOL_OUTPUT=''
typeset -gA SF_TOOL_COMMAND=()
typeset -gA SF_TOOL_SANDBOX=()
typeset -gA SF_TOOL_ALLOW_BYPASS=()
typeset -gA SF_TOOL_SETTINGS=()
typeset -gA SF_TOOL_ENVIRONMENT=()
typeset -gA SF_TOOL_RENDER=()
typeset -ga SF_TOOL_READ_PATHS=()
typeset -ga SF_TOOL_WRITE_PATHS=()
typeset -ga SF_TOOL_STATE_RECORDS=()

sf_tools_fail() {
  SF_TOOL_ERROR=$1
  SF_TOOL_STATE_RECORDS=()
  REPLY=''
  return 1
}

sf_tools_load() {
  local tools=$1 cwd=$2 harness_sandbox=$3 fence=${4-}
  local sandbox_read_paths=$5 sandbox_write_paths=$6
  local command name projected sandbox allow_bypass settings environment schema
  local render
  local -a fields read_paths write_paths
  local -A tool_command tool_sandbox tool_allow_bypass tool_settings tool_environment
  local -A tool_render
  integer index=1 read_count write_count sandboxed_tools=0
  SF_TOOL_ERROR=''
  REPLY=''
  SF_TOOL_COMMAND=()
  SF_TOOL_SANDBOX=()
  SF_TOOL_ALLOW_BYPASS=()
  SF_TOOL_SETTINGS=()
  SF_TOOL_ENVIRONMENT=()
  SF_TOOL_RENDER=()
  SF_TOOL_READ_PATHS=()
  SF_TOOL_WRITE_PATHS=()
  [[ -d $cwd ]] || {
    sf_tools_fail "session working directory is unavailable: $cwd"
    return
  }
  projected=$(sf_jq -jrn --argjson tools "$tools" \
    --argjson harness_sandbox "$harness_sandbox" \
    --argjson reads "$sandbox_read_paths" --argjson writes "$sandbox_write_paths" '
      include "lib/render";
      def field: ., "\u0000";
      def bypass_available($manifest):
        ($harness_sandbox == 1) and $manifest.sandbox and
        ($manifest.allow_sandbox_bypass // false);
      ([$tools | to_entries[] |
        .value as $tool | $tool.manifest as $manifest |
        {name:$tool.name,description:($manifest.description +
          if $harness_sandbox == 1 and $manifest.sandbox then
            "\n\nThis tool runs under its package sandbox policy."
          else "\n\nSandboxing is disabled; this tool runs with the current user permissions." end +
          if $tool.name == "shell" and bypass_available($manifest) then
            "\n\nWhen requesting an unsandboxed command, keep it to one logical operation. Split multi-step or compound commands across calls so each approval is easy to review."
          else "" end),
         input_schema:($manifest.input_schema |
          if bypass_available($manifest) then
            .properties.request_sandbox_bypass = {
              type:"boolean", description:"Request approval to run without the sandbox"} |
            .properties.sandbox_bypass_reason = {
              type:"string", minLength:1,
              description:"Explain why this tool call must run outside the sandbox"} |
            .allOf = ((.allOf // []) + [{
              if:{properties:{request_sandbox_bypass:{const:true}},
                  required:["request_sandbox_bypass"]},
              then:{required:["sandbox_bypass_reason"]}}])
          else . end)}] | tojson | field),
      ($reads | length | tostring | field),
      ($writes | length | tostring | field),
      ($reads[] | field), ($writes[] | field),
      ($tools[] | (.name | field), (.command | field),
        (.manifest.sandbox | tostring | field),
        (.manifest.allow_sandbox_bypass // false | tostring | field),
        ((.settings // "") | field), ((.manifest.environment // []) | join(" ") | field),
        (tool_render($tools; .name) | tojson | field)),
      ("ok" | field)
  ' 2>/dev/null) || {
    sf_tools_fail 'cannot inspect configured tools'
    return
  }
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} >= 4 )) && [[ $fields[2] == <-> && $fields[3] == <-> && $fields[-1] == ok ]] || {
    sf_tools_fail 'cannot inspect configured tools'
    return
  }
  schema=$fields[1]
  read_count=$fields[2]
  write_count=$fields[3]
  index=$(( read_count + write_count + 4 ))
  (( index <= ${#fields} && (${#fields} - index) % 7 == 0 )) || {
    sf_tools_fail 'cannot inspect configured tools'
    return
  }
  read_paths=( "${fields[@]:3:$read_count}" )
  write_paths=( "${fields[@]:$(( read_count + 3 )):$write_count}" )
  while (( index < ${#fields} )); do
    name=$fields[index]
    command=$fields[index+1]
    sandbox=$fields[index+2]
    allow_bypass=$fields[index+3]
    settings=$fields[index+4]
    environment=$fields[index+5]
    render=$fields[index+6]
    (( index += 7 ))
    [[ -x $command ]] || {
      sf_tools_fail "tool command is not executable: $command"
      return
    }
    tool_command[$name]=$command
    tool_sandbox[$name]=$sandbox
    tool_allow_bypass[$name]=$allow_bypass
    tool_settings[$name]=$settings
    tool_environment[$name]=$environment
    tool_render[$name]=$render
    [[ $sandbox != true ]] || sandboxed_tools=1
  done
  if (( harness_sandbox && sandboxed_tools )); then
    [[ -x $fence ]] || {
      sf_tools_fail "sandbox executable is unavailable: $fence"
      return
    }
  fi
  SF_TOOL_COMMAND=( "${(@kv)tool_command}" )
  SF_TOOL_SANDBOX=( "${(@kv)tool_sandbox}" )
  SF_TOOL_ALLOW_BYPASS=( "${(@kv)tool_allow_bypass}" )
  SF_TOOL_SETTINGS=( "${(@kv)tool_settings}" )
  SF_TOOL_ENVIRONMENT=( "${(@kv)tool_environment}" )
  SF_TOOL_RENDER=( "${(@kv)tool_render}" )
  SF_TOOL_READ_PATHS=( "${read_paths[@]}" )
  SF_TOOL_WRITE_PATHS=( "${write_paths[@]}" )
  REPLY=$schema
}

# Activity and permission previews render before the call produces output.
sf_tool_preview() {
  local id=$1 name=$2 input=$3
  REPLY=$(sf_jq -cn --arg id "$id" --arg name "$name" --argjson input "$input" \
    --argjson render "${SF_TOOL_RENDER[$name]:-null}" '
      include "lib/render";
      (render_tool($render; $name; $input; {stdout:"",stderr:"",exit_code:0}) |
        render_execution) as $rendered |
      {id:$id,name:$name,input:$input,
       user_text:$rendered.user_before,preview:$rendered.permission_preview}
  ') || return 1
}

# A refused call never runs, so its outcome is the reason alone.
sf_tool_refused() {
  local stderr=$1
  integer exit_code=$2
  SF_TOOL_STATE_RECORDS=()
  SF_TOOL_OUTPUT=$(jq -cn --arg stderr "$stderr" --argjson exit_code "$exit_code" \
    '{stdout:"",stderr:$stderr,exit_code:$exit_code}') || return
}

# The single durable form for every outcome: rendered once here, with hook
# contributions folded around the tool's own model text in lifecycle order.
sf_tool_settle() {
  local id=$1 name=$2 input=$3 output=$4 before=$5 after=$6
  REPLY=$(sf_jq -cn --arg id "$id" --arg name "$name" --argjson input "$input" \
    --argjson output "$output" --argjson render "${SF_TOOL_RENDER[$name]:-null}" \
    --arg executable "${SF_TOOL_COMMAND[$name]-}" \
    --argjson before "$before" --argjson after "$after" '
      include "lib/render";
      include "lib/session/read";
      (render_tool($render; $name; $input; $output) | render_execution) as $rendered |
      ([$before[], $rendered.model_after, $after[]] |
        map(select(. != "")) | join("\n\n")) as $model |
      ({type:"tool_result",id:$id,name:$name,input:$input,
        exit_code:$output.exit_code} +
       (if $executable == "" then {} else {executable:$executable} end) +
       (if $rendered.user_after == "" then {} else
         {user_text:$rendered.user_after} end) +
       (if $model == "" then {} else {model_text:$model} end)) as $result |
      if ($result | canonical_tool_result) then $result
      else error("invalid tool result") end
  ') || {
    sf_tools_fail "cannot render tool result: $name"
    return 1
  }
}

# Returns 0 when sandbox bypass needs approval.
sf_tool_needs_permission() {
  local name=$1 bypass=$2 reason_valid=$3
  integer harness_sandbox=$4
  (( harness_sandbox )) &&
    [[ ${SF_TOOL_ALLOW_BYPASS[$name]-false} == true && $bypass == true ]] ||
    return 1
  [[ $reason_valid == true ]] || {
    sf_tools_fail 'sandbox bypass reason is required'
    return 2
  }
}
