emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_environment_prepare] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_process_capture] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_state_control_decode] )) || source "$SF_ROOT/lib/state.zsh"

typeset -g SF_TOOL_ERROR=''
typeset -g SF_TOOL_CAPTURE_DIR=''
typeset -g SF_TOOL_TEMP_DIR=''
typeset -gA SF_TOOL_COMMAND=()
typeset -gA SF_TOOL_SANDBOX=()
typeset -gA SF_TOOL_ALLOW_BYPASS=()
typeset -gA SF_TOOL_SETTINGS=()
typeset -gA SF_TOOL_ENVIRONMENT=()
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
  local command name projected sandbox allow_bypass settings environment temp_dir schema
  local -a fields read_paths write_paths
  local -A tool_command tool_sandbox tool_allow_bypass tool_settings tool_environment
  integer index=1 read_count write_count sandboxed_tools=0
  sf_tools_cleanup
  SF_TOOL_ERROR=''
  REPLY=''
  SF_TOOL_COMMAND=()
  SF_TOOL_SANDBOX=()
  SF_TOOL_ALLOW_BYPASS=()
  SF_TOOL_SETTINGS=()
  SF_TOOL_ENVIRONMENT=()
  SF_TOOL_READ_PATHS=()
  SF_TOOL_WRITE_PATHS=()
  [[ -d $cwd ]] || {
    sf_tools_fail "session working directory is unavailable: $cwd"
    return
  }
  projected=$(jq -jrn --argjson tools "$tools" \
    --argjson harness_sandbox "$harness_sandbox" \
    --argjson reads "$sandbox_read_paths" --argjson writes "$sandbox_write_paths" '
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
        ((.settings // "") | field), ((.manifest.environment // []) | tojson | field)),
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
  (( index <= ${#fields} && (${#fields} - index) % 6 == 0 )) || {
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
    (( index += 6 ))
    [[ -x $command ]] || {
      sf_tools_fail "tool command is not executable: $command"
      return
    }
    tool_command[$name]=$command
    tool_sandbox[$name]=$sandbox
    tool_allow_bypass[$name]=$allow_bypass
    tool_settings[$name]=$settings
    tool_environment[$name]=$environment
    [[ $sandbox != true ]] || sandboxed_tools=1
  done
  if (( harness_sandbox && sandboxed_tools )); then
    [[ -x $fence ]] || {
      sf_tools_fail "sandbox executable is unavailable: $fence"
      return
    }
  fi
  sf_scratch_create tooltemps invocation || {
    sf_tools_fail 'cannot prepare tool temporary directory'
    return
  }
  temp_dir=$REPLY
  SF_TOOL_COMMAND=( "${(@kv)tool_command}" )
  SF_TOOL_SANDBOX=( "${(@kv)tool_sandbox}" )
  SF_TOOL_ALLOW_BYPASS=( "${(@kv)tool_allow_bypass}" )
  SF_TOOL_SETTINGS=( "${(@kv)tool_settings}" )
  SF_TOOL_ENVIRONMENT=( "${(@kv)tool_environment}" )
  SF_TOOL_READ_PATHS=( "${read_paths[@]}" )
  SF_TOOL_WRITE_PATHS=( "${write_paths[@]}" )
  SF_TOOL_TEMP_DIR=$temp_dir
  REPLY=$schema
}

sf_tool_result() {
  local call_id=$1 name=$2 content=$3 exit_code=$4
  SF_TOOL_STATE_RECORDS=()
  REPLY=$(jq -cn --arg call_id "$call_id" --arg name "$name" \
    --arg content "$content" --argjson exit_code "$exit_code" '
      {type:"message",role:"tool_result",call_id:$call_id,name:$name,
       content:$content,exit_code:$exit_code}
  ') || return
}

sf_tools_cleanup() {
  [[ -z $SF_TOOL_CAPTURE_DIR ]] || rm -rf -- "$SF_TOOL_CAPTURE_DIR" 2>/dev/null || true
  [[ -z $SF_TOOL_TEMP_DIR ]] || rm -rf -- "$SF_TOOL_TEMP_DIR" 2>/dev/null || true
  SF_TOOL_CAPTURE_DIR=''
  SF_TOOL_TEMP_DIR=''
}

sf_tool_bound_capture() {
  local captured=$1 result=$2 max_capture=$3 bytes marker=$'[output truncated]\n' room
  bytes=$(wc -c <"$captured") || return
  if (( bytes <= max_capture )); then
    cat "$captured" >"$result"
    return
  fi
  if (( max_capture <= ${#marker} )); then
    print -rn -- "${marker[1,max_capture]}" >"$result"
    return
  fi
  room=$(( max_capture - ${#marker} ))
  printf '%s' "$marker" >"$result" || return
  tail -c "$room" "$captured" >>"$result"
}

# Reports whether a call needs approval. The caller owns the decision.
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

sf_tool_execute() {
  local id=$1 name=$2 execution_input=$3 bypass=$4
  integer harness_sandbox=$5
  local decision=${6-} denial_reason=${7-} cwd=$8 max_capture=$9 fence=${10}
  local config_dir=${11-} session=${12-} executable=${13-} runtime=${14-}
  local tool_home=${HOME:-$cwd}
  local sandboxed use_sandbox allow_bypass settings
  local capture_dir input captured bounded control control_pipe temp native_temp command_path sandbox_log
  local expose sandbox_denial_detected=''
  local -a command locale_env states result
  integer exit_code control_size result_budget
  setopt local_options no_err_exit
  SF_TOOL_ERROR=''
  SF_TOOL_STATE_RECORDS=()
  REPLY=''
  locale_env=( LANG="${LANG:-C}" )
  [[ -z $LC_ALL ]] || locale_env+=( LC_ALL="$LC_ALL" )
  [[ -z $LC_CTYPE ]] || locale_env+=( LC_CTYPE="$LC_CTYPE" )
  [[ -z ${XDG_CONFIG_HOME-} ]] || locale_env+=( XDG_CONFIG_HOME="$XDG_CONFIG_HOME" )
  if (( ! ${+SF_TOOL_COMMAND[$name]} )); then
    sf_tool_result "$id" "$name" "tool is not allowed: $name" 127
    return
  fi
  command_path=$SF_TOOL_COMMAND[$name]
  use_sandbox=$SF_TOOL_SANDBOX[$name]
  allow_bypass=$SF_TOOL_ALLOW_BYPASS[$name]
  settings=$SF_TOOL_SETTINGS[$name]
  (( harness_sandbox )) || bypass=false
  if [[ $bypass == invalid || ( $bypass == true && $allow_bypass != true ) ]]; then
    sf_tool_result "$id" "$name" 'sandbox bypass is not allowed' 126
    return
  fi
  # Sandbox bypass requires an explicit approval decision.
  if [[ $bypass == true && $decision != approved ]]; then
    sf_tool_result "$id" "$name" "${denial_reason:-sandbox bypass denied}" 126
    return
  fi
  sf_environment_prepare "$runtime" "$SF_TOOL_ENVIRONMENT[$name]" || {
    sf_tools_fail "$SF_ENVIRONMENT_ERROR"
    return
  }
  [[ -n $SF_TOOL_TEMP_DIR && -d $SF_TOOL_TEMP_DIR ]] || {
    sf_tools_fail 'cannot prepare tool temporary directory'
    return
  }
  temp=$SF_TOOL_TEMP_DIR
  [[ -z $SF_TOOL_CAPTURE_DIR ]] || rm -rf -- "$SF_TOOL_CAPTURE_DIR" 2>/dev/null || true
  SF_TOOL_CAPTURE_DIR=''
  sf_scratch_create tools tool || {
    sf_tools_fail 'cannot prepare tool capture'
    return
  }
  capture_dir=$REPLY
  SF_TOOL_CAPTURE_DIR=$capture_dir
  {
    input="$capture_dir/input"
    bounded="$capture_dir/result"
    sf_process_control_pipe "$capture_dir"
    control_pipe=$REPLY
    print -r -- "$execution_input" >"$input" || {
      sf_tools_fail 'cannot prepare tool input'
      return
    }
    command=(/usr/bin/env -i HOME="$tool_home" "${locale_env[@]}" PATH="$PATH" TERM="${TERM:-dumb}"
      "${SF_ENVIRONMENT_VALUES[@]}" SHELLFISH_CONFIG_DIR="$config_dir"
      SHELLFISH_MAX_CAPTURE_BYTES="$max_capture" SHELLFISH_SESSION="$session"
      SHELLFISH_EXECUTABLE="$executable")
    if (( harness_sandbox )) && [[ $use_sandbox == true && $bypass != true ]]; then
      sf_temp_directory native "$temp" || {
        sf_tools_fail 'cannot resolve native temporary directory'
        return
      }
      native_temp=$REPLY
      sandbox_log="$capture_dir/sandbox.log"
      command+=(
        "$fence" --monitor --fence-log-file "$sandbox_log" --settings "$settings"
        --expose-host-path "$command_path" --expose-host-path-rw "$temp"
        --expose-host-path-rw "$control_pipe")
      [[ $native_temp == $temp ]] || command+=( --expose-host-path-rw "$native_temp" )
      for expose in "${SF_TOOL_READ_PATHS[@]}"; do
        command+=( --expose-host-path "$expose" )
      done
      for expose in "${SF_TOOL_WRITE_PATHS[@]}"; do
        command+=( --expose-host-path-rw "$expose" )
      done
      command+=(
        -- /usr/bin/env TMPDIR="$temp" TMPPREFIX="$temp/zsh"
        "${commands[zsh]}" -f -c 'exec "$1" 3>"$2"' -- "$command_path" "$control_pipe")
    else
      command+=( TMPDIR="$temp" TMPPREFIX="$temp/zsh" "$command_path" )
    fi
    sf_process_capture "$input" "$capture_dir" "$cwd" merged $max_capture \
      "${command[@]}" || {
      sf_tools_fail 'cannot capture tool output'
      return
    }
    result=( "${reply[@]}" )
    exit_code=$result[1]
    captured=$result[2]
    control=$result[4]
    control_size=$(wc -c <"$control") || {
      sf_tools_fail 'cannot inspect tool control data'
      return
    }
    (( control_size <= max_capture )) || {
      sf_tools_fail 'tool control data exceeds capture limit'
      return
    }
    if (( control_size )); then
      sf_state_control_decode "$control" || {
        sf_tools_fail 'tool returned invalid control data'
        return
      }
      [[ -z $reply[1] ]] || {
        sf_tools_fail 'tool returned invalid control data'
        return
      }
      (( ${#reply} <= 1 )) || states=( "${(@)reply[2,-1]}" )
    fi
    result_budget=$(( max_capture - control_size ))
    sf_tool_bound_capture "$captured" "$bounded" "$result_budget" || {
      sf_tools_fail 'cannot bound tool output'
      return
    }
    # Process startup denials are logged even on success, so only report a
    # denial when it accompanies a failure.
    if [[ $exit_code != 0 && -n $sandbox_log && -f $sandbox_log ]] &&
      grep -Fq ' ✗ ' "$sandbox_log"; then
      sandbox_denial_detected=true
    fi
    sandboxed=''
    if [[ $name == shell ]]; then
      sandboxed=false
      (( harness_sandbox )) && [[ $use_sandbox == true && $bypass != true ]] && sandboxed=true
    fi
    REPLY=$(jq -cn --arg call_id "$id" --arg name "$name" \
      --rawfile content "$bounded" --argjson exit_code "$exit_code" \
      --arg sandboxed "$sandboxed" --arg sandbox_denial_detected "$sandbox_denial_detected" '
        {type:"message",role:"tool_result",call_id:$call_id,name:$name,
         content:$content,exit_code:$exit_code} +
        (if $sandboxed == "" then {} else {sandboxed:($sandboxed == "true")} end) +
        (if $sandbox_denial_detected == "" then {} else {sandbox_denial_detected:true} end)
    ') || return
    SF_TOOL_STATE_RECORDS=( "${states[@]}" )
  } always {
    rm -rf -- "$capture_dir" 2>/dev/null || true
    SF_TOOL_CAPTURE_DIR=''
  }
}
