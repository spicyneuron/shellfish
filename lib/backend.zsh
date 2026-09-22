emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_process_isolated_command] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"

typeset -gA SF_BACKEND=(directory '' error '' group_file '' pid '')
typeset -ga SF_BACKEND_PARTIAL_EVENTS=()

# What one adapter invocation needs, keyed by name.
typeset -gA SF_BACKEND_PLAN=()

# One projection of the transcript on stdin: the adapter request, then the
# named backend command and its environment declarations.
sf_backend_project() {
  local tools=$1 command_field=$2
  sf_jq_fields 12 -sc --argjson tools "$tools" --arg command_field "$command_field" \
    --arg home "${HOME:A}" '
    include "lib/runtime";
    include "lib/session";
    include "lib/backend";
    def field: ., "\u0000";
    def entry($key; $value): ($key | field), ($value | field);
    select(length >= 1) |
    select(.[0] | canonical_session_header) |
    . as $records |
    ($records[0] | header_expand($home)) as $header |
    $header.runtime as $runtime |
    backend_adapter_request(
      $runtime;
      ([$records[1:][] | select(.type == "system") | .content] | join("\n\n"));
      ($records[1:] | session_messages);
      $tools
    ) as $request |
    entry("request"; $request | tojson),
    entry("cwd"; $header.cwd),
    entry("command"; $runtime.backend[$command_field]),
    entry("env_file"; $runtime.backend.env_file),
    entry("environment"; $runtime.backend.environment | join(" ")),
    entry("environment_names"; declared_environment($runtime)),
    ("ok" | field)
  ' || return 1
  SF_BACKEND_PLAN=( "${reply[@]}" )
}

sf_backend_context_window() {
  local tools=$1
  integer max_capture=$2
  local directory input output name
  local -a arguments process
  sf_backend_project "$tools" context_window_command || {
    SF_BACKEND[error]='cannot prepare context window request'
    return 1
  }
  sf_environment_load "$SF_BACKEND_PLAN[env_file]" "$SF_BACKEND_PLAN[environment]" || {
    SF_BACKEND[error]=$SF_ENVIRONMENT_ERROR
    return 1
  }
  sf_scratch_create backends context || {
    SF_BACKEND[error]='cannot prepare context window capture'
    return 1
  }
  directory=$REPLY
  input="$directory.input"
  print -r -- "$SF_BACKEND_PLAN[request]" >"$input" || {
    rm -rf -- "$directory" "$input"
    SF_BACKEND[error]='cannot prepare context window request'
    return 1
  }
  arguments=( /usr/bin/env )
  for name in ${=SF_BACKEND_PLAN[environment_names]}; do arguments+=( -u "$name" ); done
  arguments+=( "${SF_ENVIRONMENT_VALUES[@]}" "$SF_BACKEND_PLAN[command]" )
  if ! sf_process_run "$directory" "$SF_BACKEND_PLAN[cwd]" "${input:A}" "$max_capture" \
      "${arguments[@]}"; then
    rm -rf -- "$directory" "$input"
    SF_BACKEND[error]=${SF_PROCESS_ERROR:-cannot discover model context window}
    return 1
  fi
  process=( "${reply[@]}" )
  if (( process[2] )); then
    rm -rf -- "$directory" "$input"
    return $process[1]
  fi
  REPLY=null
  if (( process[1] == 0 )); then
    output=$(<"$directory/stdout")
    REPLY=$(sf_jq -ser '
      include "lib/runtime";
      select(length == 1 and (.[0] | type == "object" and keys == ["context_window"] and
        (.context_window | positive_integer))) | .[0].context_window
    ' <<<"$output" 2>/dev/null) || REPLY=null
  fi
  rm -rf -- "$directory" "$input"
}

sf_backend_run() {
  setopt local_options local_traps no_bg_nice
  local emit=${1:-:} request=$SF_BACKEND_PLAN[request] command=$SF_BACKEND_PLAN[command]
  local directory error_file group_file input_file output_pipe status_file
  local adapter_pid decoder_pid assistant event end_event kind=''
  local -a environment=( env ) process_command
  integer adapter_status=1 decoder_status=1 ended=0 signal_status=0 guard_fd run_status

  REPLY=''
  SF_BACKEND=(directory '' error '' group_file '' pid '')
  SF_BACKEND_PARTIAL_EVENTS=()
  sf_environment_load "$SF_BACKEND_PLAN[env_file]" "$SF_BACKEND_PLAN[environment]" || {
    SF_BACKEND[error]=$SF_ENVIRONMENT_ERROR
    return 1
  }
  for name in ${=SF_BACKEND_PLAN[environment_names]}; do environment+=( -u "$name" ); done
  environment+=( "${SF_ENVIRONMENT_VALUES[@]}" )
  sf_scratch_create backends request || {
    SF_BACKEND[error]='cannot prepare provider capture'
    return 1
  }
  directory=$REPLY
  error_file="$directory/error"
  group_file="$directory/process.group"
  input_file="$directory/input"
  output_pipe="$directory/output.pipe"
  status_file="$directory/process.status"
  SF_BACKEND[directory]=$directory
  SF_BACKEND[group_file]=$group_file
  print -r -- "$request" >"$input_file" && mkfifo "$output_pipe" &&
    sf_process_isolated_command "$group_file" "$status_file" "$SF_BACKEND_PLAN[cwd]" "$input_file" \
      "$output_pipe" "$error_file" /dev/null \
      "${environment[@]}" "$command" || {
    rm -rf -- "$directory"
    SF_BACKEND[directory]=''
    SF_BACKEND[group_file]=''
    SF_BACKEND[error]='cannot prepare provider capture'
    return 1
  }
  process_command=( "${reply[@]}" )
  # Hold one writer for the adapter lifetime so pre-open failure still gives
  # the decoder EOF instead of leaving it blocked on the response pipe.
  {
    exec {guard_fd}>"$output_pipe" || exit 1
    "${process_command[@]}" </dev/null >/dev/null 2>&1
    run_status=$?
    exec {guard_fd}>&-
    exit $run_status
  } &
  adapter_pid=$!
  SF_BACKEND[pid]=$adapter_pid
  trap 'signal_status=130; sf_process_stop "$adapter_pid" "$group_file"' INT USR1
  trap 'signal_status=129; sf_process_stop "$adapter_pid" "$group_file"' HUP
  trap 'signal_status=143; sf_process_stop "$adapter_pid" "$group_file"' TERM
  coproc sf_jq -jn --unbuffered '
    include "lib/session";
    include "lib/backend";
    decode_backend_response(canonical_backend_event; canonical_response)
  ' <"$output_pipe" 2>/dev/null
  decoder_pid=$!
  "$emit" '{"type":"_assistant_start"}'
  while IFS= read -r -d $'\0' kind <&p; do
    case $kind in
      event)
        if ! IFS= read -r -d $'\0' event <&p; then
          kind=invalid
          break
        fi
        SF_BACKEND_PARTIAL_EVENTS+=( "$event" )
        "$emit" "$event"
        ;;
      end)
        if ! IFS= read -r -d $'\0' end_event <&p ||
            ! IFS= read -r -d $'\0' assistant <&p; then
          kind=invalid
          break
        fi
        ended=1
        break
        ;;
      *) kind=invalid; break ;;
    esac
  done
  if [[ $kind == invalid ]]; then
    sf_process_stop "$adapter_pid" "$group_file"
  else
    sf_process_wait "$adapter_pid" "$group_file" "$status_file" || true
    adapter_status=$REPLY
    REPLY=''
  fi
  adapter_pid=''
  decoder_status=0
  wait "$decoder_pid" || decoder_status=$?
  SF_BACKEND[group_file]=''
  SF_BACKEND[pid]=''
  [[ $kind != invalid ]] || adapter_status=1
  (( decoder_status == 0 )) || kind=invalid
  if [[ $kind != invalid && $adapter_status == 0 ]] && (( ended )); then
    SF_BACKEND_PARTIAL_EVENTS=()
    "$emit" "$end_event"
    REPLY=$assistant
  fi
  if (( signal_status )); then
    rm -rf -- "$directory"
    SF_BACKEND[directory]=''
    return $signal_status
  fi
  if [[ $kind == invalid || $adapter_status != 0 || -z $REPLY ]]; then
    if [[ -s $error_file ]]; then
      SF_BACKEND[error]=$(LC_ALL=C tr -s '[:cntrl:]' ' ' <"$error_file" | cut -c 1-1000)
    elif [[ $kind == invalid ]]; then
      SF_BACKEND[error]='backend emitted an invalid event stream'
    else
      SF_BACKEND[error]='backend exited before completing a response'
    fi
    rm -rf -- "$directory"
    SF_BACKEND[directory]=''
    return 1
  fi
  rm -rf -- "$directory"
  SF_BACKEND[directory]=''
}

sf_backend_request() {
  local tools=$1 emit=${2:-:}
  sf_backend_project "$tools" command || {
    SF_BACKEND[error]='cannot prepare provider request'
    return 1
  }
  sf_backend_run "$emit"
}
