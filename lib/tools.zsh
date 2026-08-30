emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

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
  projected=$(jq -jrn --argjson tools "$tools" '
    def field: ., "\u0000";
    ($tools[] |
      (.command | field), (.manifest.sandbox | tostring | field)),
    ("ok" | field)
  ' 2>/dev/null) || {
    sf_tools_fail 'cannot inspect configured tools'
    return
  }
  fields=( "${(@0)${projected%$'\0'}}" )
  if (( ! ${#fields} )) || [[ $fields[-1] != ok ]]; then
    sf_tools_fail 'cannot inspect configured tools'
    return
  fi
  fields=( "${fields[@]:0:-1}" )
  (( ${#fields} % 2 == 0 )) || {
    sf_tools_fail 'cannot inspect configured tools'
    return
  }
  (( ${#fields} == 0 )) && { REPLY='[]'; return; }
  index=1
  while (( index <= ${#fields} )); do
    command=$fields[index]
    sandbox=$fields[index+1]
    (( index += 2 ))
    [[ -x $command ]] || {
      sf_tools_fail "tool command is not executable: $command"
      return
    }
    [[ $sandbox != true ]] || sandboxed_tools=1
  done
  REPLY=$(jq -cn --argjson tools "$tools" \
    --argjson harness_sandbox "$harness_sandbox" \
    --argjson permission_available "$permission_available" '
      def bypass_available($manifest):
        ($permission_available == 1) and ($harness_sandbox == 1) and
        $manifest.sandbox and ($manifest.allow_sandbox_bypass // false);
      [$tools | to_entries[] |
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
          else . end)}]
    ') || {
    sf_tools_fail 'cannot prepare tool schemas'
    return
  }
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

sf_tool_build_file_diff() {
  local target=$1 original=$2 result=$3 state_dir=$4
  local diff="$state_dir/file-diff"
  integer diff_status
  REPLY=''
  if diff -U1 -L '' -L '' -- "$original" "$target" >"$diff"; then
    diff_status=0
  else
    diff_status=$?
  fi
  case $diff_status in
    0) return ;;
    1) ;;
    *) sf_tools_fail "cannot render file diff result: $target"; return ;;
  esac
  awk '
    NR == 1 && /^--- / { next }
    NR == 2 && /^\+\+\+ / { next }
    { print }
  ' "$diff" >"$result" || return
  REPLY=file_diff
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
  local sandbox_read_paths=$9 sandbox_write_paths=${10}
  local tool_home=${HOME:-$cwd}
  local id name execution_input bypass sandboxed result_type tool_sandbox tool_bypass tool_settings
  local state_dir captured bounded status_file temp command_path settings sandbox_log
  local diff_field result_path original decoded sandbox_blocked=''
  local -a fields read_paths write_paths
  local -a command locale_env
  integer exit_code tail_status process_status read_count
  setopt local_options no_err_exit
  SF_TOOL_ERROR=''
  REPLY=''
  locale_env=( LANG="${LANG:-C}" )
  [[ -z $LC_ALL ]] || locale_env+=( LC_ALL="$LC_ALL" )
  [[ -z $LC_CTYPE ]] || locale_env+=( LC_CTYPE="$LC_CTYPE" )
  [[ -z ${XDG_CONFIG_HOME-} ]] || locale_env+=( XDG_CONFIG_HOME="$XDG_CONFIG_HOME" )
  decoded=$(jq -jrn --argjson reads "$sandbox_read_paths" \
    --argjson writes "$sandbox_write_paths" '
      def field: ., "\u0000";
      ($reads | length | tostring | field),
      ($reads[] | field), ($writes[] | field), ("ok" | field)
  ' 2>/dev/null) || { sf_tools_fail 'cannot decode sandbox paths'; return; }
  fields=( "${(@0)${decoded%$'\0'}}" )
  (( ${#fields} >= 2 )) && [[ $fields[1] == <-> && $fields[-1] == ok ]] || {
    sf_tools_fail 'cannot decode sandbox paths'
    return
  }
  read_count=$fields[1]
  (( read_count <= ${#fields} - 2 )) || {
    sf_tools_fail 'cannot decode sandbox paths'
    return
  }
  read_paths=( "${fields[@]:1:$read_count}" )
  write_paths=( "${fields[@]:$(( read_count + 1 )):-1}" )
  decoded=$(jq -jrn --argjson tools "$tools" --argjson call "$call" '
    def field: ., "\u0000";
    ($call | .id | field), ($call | .name | field),
    ($call.input | del(.request_sandbox_bypass, .sandbox_bypass_reason) | tojson | field),
    ($call.input | if has("request_sandbox_bypass") then
      if (.request_sandbox_bypass | type) == "boolean"
      then (.request_sandbox_bypass | tostring) else "invalid" end
    else "false" end | field),
    ($tools[] | select(.name == $call.name) |
      (.command | field), (.manifest.sandbox | tostring | field),
      (.manifest.allow_sandbox_bypass // false | tostring | field),
      (.manifest.result.path_field // "" | field), (.settings | tojson | field)),
    ("ok" | field)
  ' 2>/dev/null) || { sf_tools_fail 'cannot decode tool call'; return; }
  fields=( "${(@0)${decoded%$'\0'}}" )
  (( ${#fields} && $fields[-1] == ok )) || {
    sf_tools_fail 'cannot decode tool call'
    return
  }
  fields=( "${fields[@]:0:-1}" )
  if (( ${#fields} == 4 )); then
    id=$fields[1]
    name=$fields[2]
    sf_tool_result "$id" "$name" "tool is not allowed: $name" 127
    return
  fi
  (( ${#fields} == 9 )) || { sf_tools_fail 'cannot decode tool call'; return; }
  id=$fields[1]
  name=$fields[2]
  execution_input=$fields[3]
  bypass=$fields[4]
  command_path=$fields[5]
  tool_sandbox=$fields[6]
  tool_bypass=$fields[7]
  diff_field=$fields[8]
  tool_settings=$fields[9]
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
  sf_tools_cleanup
  state_dir=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-tool.XXXXXX") || {
    sf_tools_fail 'cannot prepare tool capture'
    return
  }
  SF_TOOL_STATE_DIR=$state_dir
  {
    captured="$state_dir/captured"
    bounded="$state_dir/result"
    status_file="$state_dir/status"
    if [[ -n $diff_field ]]; then
      decoded=$(jq -jer --arg field "$diff_field" '
        (.[$field] | select(type == "string")), "\u0000", "ok", "\u0000"
      ' <<<"$execution_input") || { sf_tools_fail 'cannot decode file result path'; return; }
      fields=( "${(@0)${decoded%$'\0'}}" )
      (( ${#fields} == 2 )) && [[ $fields[2] == ok ]] || {
        sf_tools_fail 'cannot decode file result path'
        return
      }
      result_path=$fields[1]
      [[ $result_path == /* ]] || result_path="$cwd/$result_path"
      original="$state_dir/original"
      if [[ -e $result_path || -L $result_path ]]; then
        if [[ -f $result_path && -r $result_path ]]; then
          cp -- "$result_path" "$original" || {
            sf_tools_fail "cannot snapshot file result: $result_path"
            return
          }
        else
          result_path=''
        fi
      else
        : >"$original" || return 1
      fi
    fi
    if (( harness_sandbox )) && [[ $tool_sandbox == true && $bypass != true ]]; then
      settings="$state_dir/fence.jsonc"
      sandbox_log="$state_dir/sandbox.log"
      print -r -- "$tool_settings" >"$settings" || return 1
      command=(/usr/bin/env -i HOME="$tool_home" "${locale_env[@]}" PATH="$PATH" TERM="${TERM:-dumb}"
        TMPPREFIX=/tmp/fence/zsh SHELLFISH_MAX_CAPTURE_BYTES="$max_capture"
        "$fence" --monitor --fence-log-file "$sandbox_log" --settings "$settings"
        --expose-host-path "$settings" --expose-host-path "$command_path")
      for decoded in "${read_paths[@]}"; do
        command+=( --expose-host-path "$decoded" )
      done
      for decoded in "${write_paths[@]}"; do
        command+=( --expose-host-path-rw "$decoded" )
      done
      command+=(
        -- "$command_path")
    else
      # env -i drops TMPDIR; TMPPREFIX separately controls Zsh here-documents.
      temp="$state_dir/tmp"
      mkdir "$temp" || return 1
      command=(/usr/bin/env -i HOME="$tool_home" "${locale_env[@]}" PATH="$PATH" TERM="${TERM:-dumb}"
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
    if [[ -n $result_path && $exit_code == 0 ]]; then
      sf_tool_build_file_diff "$result_path" "$original" "$bounded" "$state_dir" || return 1
      result_type=$REPLY
    fi
    # Process startup denials are logged even on success, so a violation only
    # counts as a block when it accompanies a failure.
    if [[ $exit_code != 0 && -n $sandbox_log && -f $sandbox_log ]] &&
      grep -Fq ' ✗ ' "$sandbox_log"; then
      sandbox_blocked=true
    fi
    sandboxed=''
    if [[ $name == shell ]]; then
      sandboxed=false
      (( harness_sandbox )) && [[ $tool_sandbox == true && $bypass != true ]] && sandboxed=true
    fi
    REPLY=$(jq -cn --arg call_id "$id" --arg name "$name" \
      --rawfile content "$bounded" --argjson exit_code "$exit_code" --arg result_type "$result_type" \
      --arg sandboxed "$sandboxed" --arg sandbox_blocked "$sandbox_blocked" '
        {type:"message",role:"tool_result",call_id:$call_id,name:$name,
         content:$content,exit_code:$exit_code} +
        (if $result_type == "" then {} else {result_type:$result_type} end) +
        (if $sandboxed == "" then {} else {sandboxed:($sandboxed == "true")} end) +
        (if $sandbox_blocked == "" then {} else {sandbox_blocked:true} end)
    ') || return
  } always {
    sf_tools_cleanup
  }
}
