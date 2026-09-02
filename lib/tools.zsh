emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_TOOL_ERROR=''
typeset -g SF_TOOL_STATE_DIR=''
typeset -g SF_TOOL_ACTIVE_PID=''
integer -g SF_TOOL_INTERRUPTED=0

sf_tools_fail() {
  SF_TOOL_ERROR=$1
  return 1
}

sf_tools_load() {
  local tools=$1 permission_available=${2:-0} cwd=$3
  local max_capture=$4 harness_sandbox=$5 fence=${6-}
  local command projected sandbox
  local -a fields
  integer index=1 sandboxed_tools=0
  SF_TOOL_ERROR=''
  REPLY=''
  [[ -d $cwd ]] || {
    sf_tools_fail "session working directory is unavailable: $cwd"
    return
  }
  projected=$(jq -jrn --argjson tools "$tools" \
    --argjson harness_sandbox "$harness_sandbox" \
    --argjson permission_available "$permission_available" '
      def field: ., "\u0000";
      def bypass_available($manifest):
        ($permission_available == 1) and ($harness_sandbox == 1) and
        $manifest.sandbox and ($manifest.allow_sandbox_bypass // false);
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
  REPLY=$fields[1]
  index=2
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
}

sf_tool_result() {
  local call_id=$1 name=$2 content=$3 exit_code=$4
  REPLY=$(jq -cn --arg call_id "$call_id" --arg name "$name" \
    --arg content "$content" --argjson exit_code "$exit_code" '
      {type:"message",role:"tool_result",call_id:$call_id,name:$name,
       content:$content,exit_code:$exit_code}
  ') || return
}

sf_tools_cleanup() {
  [[ -z $SF_TOOL_STATE_DIR ]] || rm -rf -- "$SF_TOOL_STATE_DIR" 2>/dev/null || true
  SF_TOOL_STATE_DIR=''
}

sf_tool_bound_capture() {
  local captured=$1 result=$2 max_capture=$3 bytes marker=$'[output truncated]\n' room
  bytes=$(wc -c <"$captured") || return
  if (( bytes <= max_capture )); then
    cat "$captured" >"$result"
    return
  fi
  room=$(( max_capture - ${#marker} ))
  (( room >= 0 )) || room=0
  printf '%s' "$marker" >"$result" || return
  (( room == 0 )) || tail -c "$room" "$captured" >>"$result"
}

# Reports whether a call needs approval. The caller owns the decision.
sf_tool_needs_permission() {
  local name=$1 input=$2 tools=$3
  integer harness_sandbox=$4
  (( harness_sandbox )) || return 1
  jq -e --arg name "$name" --argjson input "$input" '
    if any(.[]; .name == $name and (.manifest.allow_sandbox_bypass // false)) and
        $input.request_sandbox_bypass == true then
      if ($input.sandbox_bypass_reason | type) == "string" and
          ($input.sandbox_bypass_reason | length) > 0 then true
      else error("sandbox bypass reason is required") end
    else false end
  ' <<<"$tools" >/dev/null 2>&1
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    *) sf_tools_fail 'sandbox bypass reason is required'; return 2 ;;
  esac
}

sf_tool_execute() {
  local call=$1 harness_sandbox=$2 decision=${3-} denial_reason=${4-}
  local tools=$5 cwd=$6 max_capture=$7 fence=$8
  local sandbox_read_paths=$9 sandbox_write_paths=${10} config_dir=${11-}
  local session_id=${12-}
  local tool_home=${HOME:-$cwd}
  local id name execution_input bypass sandboxed tool_sandbox tool_bypass tool_settings
  local state_dir captured bounded status_file temp native_temp command_path sandbox_log
  local decoded sandbox_denial_detected=''
  local -a fields read_paths write_paths
  local -a command locale_env
  integer exit_code tail_status process_status read_count write_count call_offset
  setopt local_options no_err_exit
  SF_TOOL_ERROR=''
  REPLY=''
  locale_env=( LANG="${LANG:-C}" )
  [[ -z $LC_ALL ]] || locale_env+=( LC_ALL="$LC_ALL" )
  [[ -z $LC_CTYPE ]] || locale_env+=( LC_CTYPE="$LC_CTYPE" )
  [[ -z ${XDG_CONFIG_HOME-} ]] || locale_env+=( XDG_CONFIG_HOME="$XDG_CONFIG_HOME" )
  decoded=$(jq -jrn --argjson reads "$sandbox_read_paths" \
    --argjson writes "$sandbox_write_paths" --argjson tools "$tools" --argjson call "$call" '
    def field: ., "\u0000";
    ($reads | length | tostring | field),
    ($writes | length | tostring | field),
    ($reads[] | field), ($writes[] | field),
    ($call | .id | field), ($call | .name | field),
    ($call.input | del(.request_sandbox_bypass, .sandbox_bypass_reason) | tojson | field),
    ($call.input | if has("request_sandbox_bypass") then
      if (.request_sandbox_bypass | type) == "boolean"
      then (.request_sandbox_bypass | tostring) else "invalid" end
    else "false" end | field),
    ($tools[] | select(.name == $call.name) |
      (.command | field), (.manifest.sandbox | tostring | field),
      (.manifest.allow_sandbox_bypass // false | tostring | field),
      ((.settings // "") | field)),
    ("ok" | field)
  ' 2>/dev/null) || { sf_tools_fail 'cannot decode tool call'; return; }
  fields=( "${(@0)${decoded%$'\0'}}" )
  (( ${#fields} >= 7 )) && [[ $fields[1] == <-> && $fields[2] == <-> && $fields[-1] == ok ]] || {
    sf_tools_fail 'cannot decode tool call'
    return
  }
  read_count=$fields[1]
  write_count=$fields[2]
  call_offset=$(( read_count + write_count + 3 ))
  (( call_offset <= ${#fields} - 4 )) || {
    sf_tools_fail 'cannot decode tool call'
    return
  }
  read_paths=( "${fields[@]:2:$read_count}" )
  write_paths=( "${fields[@]:$(( read_count + 2 )):$write_count}" )
  fields=( "${fields[@]:$(( call_offset - 1 )):-1}" )
  if (( ${#fields} == 4 )); then
    id=$fields[1]
    name=$fields[2]
    sf_tool_result "$id" "$name" "tool is not allowed: $name" 127
    return
  fi
  (( ${#fields} == 8 )) || { sf_tools_fail 'cannot decode tool call'; return; }
  id=$fields[1]
  name=$fields[2]
  execution_input=$fields[3]
  bypass=$fields[4]
  command_path=$fields[5]
  tool_sandbox=$fields[6]
  tool_bypass=$fields[7]
  tool_settings=$fields[8]
  (( harness_sandbox )) || bypass=false
  if [[ $bypass == invalid || ( $bypass == true && $tool_bypass != true ) ]]; then
    sf_tool_result "$id" "$name" 'sandbox bypass is not allowed' 126
    return
  fi
  # Sandbox bypass requires an explicit approval decision.
  if [[ $bypass == true && $decision != approved ]]; then
    sf_tool_result "$id" "$name" "${denial_reason:-sandbox bypass denied}" 126
    return
  fi
  [[ -n $session_id && $session_id != . && $session_id != .. ]] || {
    sf_tools_fail 'tool session ID is not available'
    return
  }
  sf_scratch_directory tooltemps "session-$session_id-tmp" || {
    sf_tools_fail 'cannot prepare tool temporary directory'
    return
  }
  temp=$REPLY
  sf_tools_cleanup
  sf_scratch_create tools tool || {
    sf_tools_fail 'cannot prepare tool capture'
    return
  }
  state_dir=$REPLY
  SF_TOOL_STATE_DIR=$state_dir
  {
    captured="$state_dir/captured"
    bounded="$state_dir/result"
    status_file="$state_dir/status"
    if (( harness_sandbox )) && [[ $tool_sandbox == true && $bypass != true ]]; then
      sf_temp_directory native "$temp" || {
        sf_tools_fail 'cannot resolve native temporary directory'
        return
      }
      native_temp=$REPLY
      sandbox_log="$state_dir/sandbox.log"
      command=(/usr/bin/env -i HOME="$tool_home" "${locale_env[@]}" PATH="$PATH" TERM="${TERM:-dumb}"
        SHELLFISH_CONFIG_DIR="$config_dir"
        SHELLFISH_MAX_CAPTURE_BYTES="$max_capture"
        "$fence" --monitor --fence-log-file "$sandbox_log" --settings "$tool_settings"
        --expose-host-path "$command_path" --expose-host-path-rw "$temp")
      [[ $native_temp == $temp ]] || command+=( --expose-host-path-rw "$native_temp" )
      for decoded in "${read_paths[@]}"; do
        command+=( --expose-host-path "$decoded" )
      done
      for decoded in "${write_paths[@]}"; do
        command+=( --expose-host-path-rw "$decoded" )
      done
      command+=(
        -- /usr/bin/env TMPDIR="$temp" TMPPREFIX="$temp/zsh" "$command_path")
    else
      command=(/usr/bin/env -i HOME="$tool_home" "${locale_env[@]}" PATH="$PATH" TERM="${TERM:-dumb}"
        SHELLFISH_CONFIG_DIR="$config_dir"
        TMPDIR="$temp" TMPPREFIX="$temp/zsh"
        SHELLFISH_MAX_CAPTURE_BYTES="$max_capture" "$command_path")
    fi
    coproc {
      (cd "$cwd" && print -r -- "$execution_input" | "${command[@]}" 2>&1) |
        tail -c "$(( max_capture + 1 ))" >"$captured"
      local -a child_statuses=( $pipestatus )
      print -r -- "$child_statuses[1] $child_statuses[2]" >"$status_file"
    }
    SF_TOOL_ACTIVE_PID=$!
    wait "$SF_TOOL_ACTIVE_PID" || process_status=$?
    SF_TOOL_ACTIVE_PID=''
    (( process_status == 0 )) || {
      sf_tools_fail 'tool process exited without status'
      return
    }
    read -r exit_code tail_status <"$status_file" || {
      sf_tools_fail 'cannot inspect tool process status'
      return
    }
    if (( SF_TOOL_INTERRUPTED )); then
      return 130
    fi
    (( tail_status == 0 )) || {
      sf_tools_fail 'cannot capture tool output'
      return
    }
    sf_tool_bound_capture "$captured" "$bounded" "$max_capture" || {
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
      (( harness_sandbox )) && [[ $tool_sandbox == true && $bypass != true ]] && sandboxed=true
    fi
    REPLY=$(jq -cn --arg call_id "$id" --arg name "$name" \
      --rawfile content "$bounded" --argjson exit_code "$exit_code" \
      --arg sandboxed "$sandboxed" --arg sandbox_denial_detected "$sandbox_denial_detected" '
        {type:"message",role:"tool_result",call_id:$call_id,name:$name,
         content:$content,exit_code:$exit_code} +
        (if $sandboxed == "" then {} else {sandboxed:($sandboxed == "true")} end) +
        (if $sandbox_denial_detected == "" then {} else {sandbox_denial_detected:true} end)
    ') || return
  } always {
    sf_tools_cleanup
  }
}
