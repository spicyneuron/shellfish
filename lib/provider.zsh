emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_process_isolated_command] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"

typeset -gA SF_PROVIDER=(directory '' error '' group_file '' pid '')
typeset -ga SF_PROVIDER_PARTIAL_EVENTS=()

# What one provider invocation needs, keyed by name.
typeset -gA SF_PROVIDER_PLAN=()

# One projection of the transcript on stdin: the provider request and command.
sf_provider_project() {
  local tools=$1 model=${2:-null}
  sf_jq_fields -sc --argjson tools "$tools" --argjson model "$model" --arg share "$SF_SHARE" \
      --arg home "${HOME:+${HOME:A}}" '
    include "lib/fields";
    include "lib/profile";
    include "lib/session";
    include "lib/provider";
    select(length >= 1) |
    select(.[0] | canonical_session_header) |
    . as $records |
    ($records[0] | header_expand($share; $home) |
      if $model == null then . else .model = $model end) as $header |
    provider_request(
      $header.model;
      ($header.profile.system[0].text // "");
      ($records[1:] | session_messages);
      $tools
    ) as $request |
    entry("request"; $request | tojson),
    entry("cwd"; $header.cwd),
    entry("command"; $header.model.provider + "/run"),
    ("ok" | field)
  ' || return 1
  SF_PROVIDER_PLAN=( "${reply[@]}" )
}

# Run COMMAND once on the request in SF_PROVIDER_PLAN. reply holds exit_code,
# interrupted, stdout, stderr, and their byte counts; output past MAX_CAPTURE
# keeps only its tail.
sf_provider_capture() {
  local command=$1 directory input
  integer max_capture=$2
  local -A process
  sf_environment_load || {
    SF_PROVIDER[error]=$SF_ENVIRONMENT_ERROR
    return 1
  }
  sf_scratch_directory provider-capture || {
    SF_PROVIDER[error]='cannot prepare provider capture'
    return 1
  }
  directory=$REPLY
  input="$directory.input"
  print -r -- "$SF_PROVIDER_PLAN[request]" >"$input" || {
    rm -rf -- "$directory" "$input"
    SF_PROVIDER[error]='cannot prepare provider request'
    return 1
  }
  if ! sf_process_run "$directory" "$SF_PROVIDER_PLAN[cwd]" "${input:A}" "$max_capture" : \
      /usr/bin/env "${SF_ENVIRONMENT_VALUES[@]}" "$command"; then
    rm -rf -- "$directory" "$input"
    SF_PROVIDER[error]=${SF_PROCESS_ERROR:-cannot run provider}
    return 1
  fi
  process=( "${reply[@]}" )
  process[stdout]=$(<"$directory/stdout")
  process[stderr]=$(<"$directory/stderr")
  rm -rf -- "$directory" "$input"
  reply=( "${(@kv)process}" )
}

# Discover capacity for the request already in SF_PROVIDER_PLAN.
sf_provider_context_window() {
  local command=$1
  integer max_capture=$2
  local -A process
  sf_provider_capture "$command" "$max_capture" || return
  process=( "${reply[@]}" )
  (( ! process[interrupted] )) || return $process[exit_code]
  REPLY=null
  if (( process[exit_code] == 0 && process[stdout_bytes] <= max_capture &&
      process[stderr_bytes] <= max_capture )); then
    REPLY=$(sf_jq -ser '
      include "lib/profile";
      select(length == 1 and (.[0] | type == "object" and keys == ["context_window"] and
        (.context_window | positive_integer))) | .[0].context_window
    ' <<<"$process[stdout]" 2>/dev/null) || REPLY=null
  fi
}

sf_provider_run() {
  setopt local_options local_traps no_bg_nice
  local emit=${1:-:} request=$SF_PROVIDER_PLAN[request] command=$SF_PROVIDER_PLAN[command]
  local directory error_file group_file input_file output_pipe status_file
  local provider_pid decoder_pid assistant event kind=''
  local -a process_command
  integer provider_status=1 decoder_status=1 ended=0 signal_status=0 guard_fd run_status

  REPLY=''
  SF_PROVIDER=(directory '' error '' group_file '' pid '')
  SF_PROVIDER_PARTIAL_EVENTS=()
  sf_environment_load || {
    SF_PROVIDER[error]=$SF_ENVIRONMENT_ERROR
    return 1
  }
  sf_scratch_directory provider || {
    SF_PROVIDER[error]='cannot prepare provider capture'
    return 1
  }
  directory=$REPLY
  error_file="$directory/error"
  group_file="$directory/process.group"
  input_file="$directory/input"
  output_pipe="$directory/output.pipe"
  status_file="$directory/process.status"
  SF_PROVIDER[directory]=$directory
  SF_PROVIDER[group_file]=$group_file
  print -r -- "$request" >"$input_file" && mkfifo "$output_pipe" &&
    sf_process_isolated_command "$group_file" "$status_file" "$SF_PROVIDER_PLAN[cwd]" "$input_file" \
      "$output_pipe" "$error_file" /dev/null \
      env "${SF_ENVIRONMENT_VALUES[@]}" "$command" || {
    rm -rf -- "$directory"
    SF_PROVIDER[directory]=''
    SF_PROVIDER[group_file]=''
    SF_PROVIDER[error]='cannot prepare provider capture'
    return 1
  }
  process_command=( "${reply[@]}" )
  # Hold one writer for the provider lifetime so pre-open failure still gives
  # the decoder EOF instead of leaving it blocked on the response pipe.
  {
    exec {guard_fd}>"$output_pipe" || exit 1
    "${process_command[@]}" </dev/null >/dev/null 2>&1
    run_status=$?
    exec {guard_fd}>&-
    exit $run_status
  } &
  provider_pid=$!
  SF_PROVIDER[pid]=$provider_pid
  trap 'signal_status=130; sf_process_stop "$provider_pid" "$group_file"' INT USR1
  trap 'signal_status=129; sf_process_stop "$provider_pid" "$group_file"' HUP
  trap 'signal_status=143; sf_process_stop "$provider_pid" "$group_file"' TERM
  coproc sf_jq -jn --unbuffered '
    include "lib/session";
    include "lib/provider";
    decode_provider_response(canonical_response)
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
        SF_PROVIDER_PARTIAL_EVENTS+=( "$event" )
        "$emit" "$event"
        ;;
      end)
        if ! IFS= read -r -d $'\0' assistant <&p; then
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
    sf_process_stop "$provider_pid" "$group_file"
  else
    sf_process_wait "$provider_pid" "$group_file" "$status_file" || true
    provider_status=$REPLY
    REPLY=''
  fi
  provider_pid=''
  decoder_status=0
  wait "$decoder_pid" || decoder_status=$?
  SF_PROVIDER[group_file]=''
  SF_PROVIDER[pid]=''
  [[ $kind != invalid ]] || provider_status=1
  (( decoder_status == 0 )) || kind=invalid
  if [[ $kind != invalid && $provider_status == 0 ]] && (( ended )); then
    SF_PROVIDER_PARTIAL_EVENTS=()
    REPLY=$assistant
  fi
  if (( signal_status )); then
    rm -rf -- "$directory"
    SF_PROVIDER[directory]=''
    return $signal_status
  fi
  if [[ $kind == invalid || $provider_status != 0 || -z $REPLY ]]; then
    if [[ -s $error_file ]]; then
      SF_PROVIDER[error]=$(LC_ALL=C tr -s '[:cntrl:]' ' ' <"$error_file" | cut -c 1-1000)
    elif [[ $kind == invalid ]]; then
      SF_PROVIDER[error]='provider emitted an invalid event stream'
    else
      SF_PROVIDER[error]='provider exited before completing a response'
    fi
    rm -rf -- "$directory"
    SF_PROVIDER[directory]=''
    return 1
  fi
  rm -rf -- "$directory"
  SF_PROVIDER[directory]=''
}
