emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

typeset -g SF_TOOL_ERROR=''

sf_tools_fail() {
  SF_TOOL_ERROR=$1
  REPLY=''
  return 1
}

sf_tools_load() {
  local tools=$1 cwd=$2 harness_sandbox=$3 fence=${4-}
  local command projected sandbox schema
  local -a fields
  integer index=2 sandboxed_tools=0
  SF_TOOL_ERROR=''
  REPLY=''
  [[ -d $cwd ]] || {
    sf_tools_fail "session working directory is unavailable: $cwd"
    return
  }
  projected=$(sf_jq -jrn --argjson tools "$tools" \
    --argjson harness_sandbox "$harness_sandbox" '
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
      ($tools[] | (.command | field), (.manifest.sandbox | tostring | field)),
      ("ok" | field)
  ' 2>/dev/null) || {
    sf_tools_fail 'cannot inspect configured tools'
    return
  }
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} >= 2 && (${#fields} - 2) % 2 == 0 )) && [[ $fields[-1] == ok ]] || {
    sf_tools_fail 'cannot inspect configured tools'
    return
  }
  schema=$fields[1]
  while (( index < ${#fields} )); do
    command=$fields[index]
    sandbox=$fields[index+1]
    (( index += 2 ))
    [[ -x $command ]] || {
      sf_tools_fail "tool command is not executable: $command"
      return
    }
    [[ $sandbox != true ]] || sandboxed_tools=1
  done
  if (( harness_sandbox && sandboxed_tools )); then
    [[ -x $fence ]] || {
      sf_tools_fail "sandbox executable is unavailable: $fence"
      return
    }
  fi
  REPLY=$schema
}
