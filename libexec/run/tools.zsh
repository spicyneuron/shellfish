emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_run_component_execute] )) || source "$SF_ROOT/libexec/run/component.zsh"

typeset -g SF_RUN_TOOL_ERROR=''

# The call being executed, as the turn's step planned it.
typeset -gA SF_TOOL_PLAN=()

sf_run_tool_refused() {
  local reason=$1 ran=${3:-false}
  integer exit_code=$2
  REPLY=$(jq -cn --arg reason "$reason" --argjson ran "$ran" \
    --argjson exit_code "$exit_code" '
    {output:{stdout:$reason,stderr:$reason,exit_code:$exit_code},ran:$ran}
  ')
}

# Content parts accumulate for the result, within the content limit per call.
sf_run_tool_line() {
  local parts
  integer bytes
  sf_process_bytes "$1"
  bytes=$REPLY
  sf_run_component_line "$1" content || return
  [[ -n $REPLY ]] || return 0
  (( (content_bytes += bytes) <= max_content )) || return 0
  parts=$(sf_jq -c '
    include "lib/session";
    if .content | type == "array" and length > 0 and all(.[]; canonical_content_part)
    then .content[] else error("invalid content") end
  ' <<<"$REPLY" 2>/dev/null) || { SF_COMPONENT[error]=invalid; return 1; }
  content+=( "${(@f)parts}" )
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
  local -a arguments content process_command sandbox_arguments temp_paths
  integer max_capture=$SF_TOOL_PLAN[max_capture] max_content=$SF_RUN[max_content]
  integer content_bytes=0

  SF_RUN_TOOL_ERROR=''
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
    "${SF_ENVIRONMENT_VALUES[@]}"
    "HOME=${HOME:-$cwd}" "PATH=$PATH" "TERM=${TERM:-dumb}"
    "LANG=${LANG:-C}" "SHELLFISH_DIR=$config_dir"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture" "SHELLFISH_MAX_CONTENT_BYTES=$max_content"
    "SHELLFISH_SESSION=$session" "SHELLFISH_CONFIG=$SF_RUN[config]"
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
  sf_run_component_execute "$capture" "${cwd:A}" "${stdin:A}" "$max_capture" "$max_content" \
    sf_run_tool_line "${process_command[@]}" || { SF_RUN_TOOL_ERROR=$REPLY; return 1; }
  # Only a completed call can overflow, so interruption and invalid data win.
  [[ $reply[1] != ok ]] || (( content_bytes <= max_content )) || reply[1]=overflow
  case $reply[1] in
    (interrupted) return $reply[2] ;;
    (invalid) SF_RUN_TOOL_ERROR='tool returned invalid control data'; return 1 ;;
    (overflow) sf_run_tool_refused 'tool result exceeds content limit' 1 true; return ;;
  esac
  if (( $#content )); then
    REPLY=$(print -rl -- "$REPLY" "${content[@]}" | jq -cs '.[0] + {content:.[1:]}') ||
      { SF_RUN_TOOL_ERROR='cannot decode tool content'; return 1; }
  fi
  if (( reply[2] )) && grep -qs $'✗' "$capture/sandbox.log"; then
    REPLY=$(jq -c '.output.stdout += "\n<sandbox_notice>A denial was detected during this tool call. This does not necessarily mean the tool failed.</sandbox_notice>"' <<<"$REPLY") ||
      { SF_RUN_TOOL_ERROR='cannot decode tool result'; return 1; }
  fi
  } always {
    rm -rf -- "$capture"
    rm -f -- "$stdin"
  }
}

# The outcome arrives on stdin, since its content can exceed an argument.
sf_run_tool_complete() {
  sf_run_reduce '
    input as $outcome |
    entry("result"; tool_result($component; $outcome) | tojson),
    entry("post_request"; $request + {tool_response:$outcome.output} | tojson)
  ' --argjson component "$SF_TOOL_PLAN[component]" \
    --argjson request "$SF_TOOL_PLAN[request]" <<<"$1" ||
    { SF_RUN_TOOL_ERROR="cannot finish tool result: $SF_TOOL_PLAN[name]"; return 1; }
}
