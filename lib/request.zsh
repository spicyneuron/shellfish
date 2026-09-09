emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_process_isolated_command] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_environment_prepare] )) || source "$SF_ROOT/lib/environment.zsh"

typeset -gA SF_REQUEST=(
  assistant '' directory '' error '' group_file '' pid '' result ''
)
typeset -ga SF_REQUEST_PARTIAL_EVENTS=()

sf_request_build() {
  local runtime=$1 tools=$2
  sf_jq -sce --argjson runtime "$runtime" --argjson tools "$tools" '
    include "lib/runtime/schema";
    include "lib/session/request";
    . as $records |
    {
      format_version:1,
      system:([$records[] | select(.type == "system") | .content] | join("\n\n")),
      messages:($records | request_messages),
      tools:$tools,
      options:{request:$runtime.profile.request},
      transport:($runtime.backend | {endpoint,insecure_tls,http_timeout,http_stall})
    } | select(canonical_request)
  '
}

sf_request_run() {
  local request=$1 command=$2 runtime=$3 selected=$4 emit=${5:-:}
  local directory error_file group_file input_file output_pipe status_file
  local adapter_pid decoder_pid event end_event kind='' name
  local -a environment=( env ) process_command
  integer adapter_status=1 decoder_status=1 ended=0

  SF_REQUEST[assistant]=''
  SF_REQUEST[directory]=''
  SF_REQUEST[error]=''
  SF_REQUEST[group_file]=''
  SF_REQUEST_PARTIAL_EVENTS=()
  SF_REQUEST[pid]=''
  SF_REQUEST[result]=''
  sf_environment_prepare "$runtime" "$selected" || {
    SF_REQUEST[error]=$SF_ENVIRONMENT_ERROR
    return 1
  }
  for name in $SF_ENVIRONMENT_NAMES; do
    environment+=( -u "$name" )
  done
  environment+=( "${SF_ENVIRONMENT_VALUES[@]}" )
  sf_scratch_create backends request || {
    SF_REQUEST[error]='cannot prepare provider capture'
    return 1
  }
  directory=$REPLY
  error_file="$directory/error"
  group_file="$directory/process.group"
  input_file="$directory/input"
  output_pipe="$directory/output.pipe"
  status_file="$directory/process.status"
  SF_REQUEST[directory]=$directory
  SF_REQUEST[group_file]=$group_file
  print -r -- "$request" >"$input_file" && mkfifo "$output_pipe" &&
    sf_process_isolated_command "$group_file" "$status_file" "$PWD" "$input_file" \
      "$output_pipe" "$error_file" /dev/null separate \
      "${environment[@]}" "$command" || {
    rm -rf -- "$directory"
    SF_REQUEST[directory]=''
    SF_REQUEST[group_file]=''
    SF_REQUEST[error]='cannot prepare provider capture'
    return 1
  }
  process_command=( "${reply[@]}" )
  "${process_command[@]}" </dev/null >/dev/null 2>&1 &
  adapter_pid=$!
  SF_REQUEST[pid]=$adapter_pid
  coproc sf_jq -jn --unbuffered '
    include "lib/runtime/schema";
    include "lib/request";
    decode_backend_response(canonical_backend_event; canonical_assistant_message)
  ' <"$output_pipe" 2>/dev/null
  decoder_pid=$!
  "$emit" '{"type":"_assistant_start"}'
  # Decoder metadata is NUL-framed; arbitrary stop text ends the response payload.
  while IFS= read -r -d $'\0' kind <&p; do
    case $kind in
      event)
        if ! IFS= read -r -d $'\0' event <&p; then
          kind=invalid
          break
        fi
        SF_REQUEST_PARTIAL_EVENTS+=( "$event" )
        "$emit" "$event"
        ;;
      end)
        if ! IFS= read -r -d $'\0' end_event <&p; then
          kind=invalid
          break
        fi
        SF_REQUEST[result]=$(<&p)
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
  fi
  decoder_status=0
  wait "$decoder_pid" || decoder_status=$?
  SF_REQUEST[pid]=''
  SF_REQUEST[group_file]=''
  if [[ $kind == invalid ]]; then
    adapter_status=1
  fi
  (( decoder_status == 0 )) || kind=invalid
  if [[ $kind != invalid && $adapter_status == 0 ]] && (( ended )); then
    SF_REQUEST[assistant]=${SF_REQUEST[result]%%$'\0'*}
    [[ -z $SF_REQUEST[assistant] ]] || SF_REQUEST_PARTIAL_EVENTS=()
  fi
  # A completed response is announced only once the adapter also exits zero.
  [[ -z $SF_REQUEST[assistant] ]] || "$emit" "$end_event"
  if [[ $kind == invalid || $adapter_status != 0 || -z $SF_REQUEST[assistant] ]]; then
    if [[ -s $error_file ]]; then
      SF_REQUEST[error]=$(LC_ALL=C tr -s '[:cntrl:]' ' ' <"$error_file" | cut -c 1-1000)
    elif [[ $kind == invalid ]]; then
      SF_REQUEST[error]='backend emitted an invalid event stream'
    else
      SF_REQUEST[error]='backend exited before completing a response'
    fi
    rm -rf -- "$directory"
    SF_REQUEST[directory]=''
    return 1
  fi
  rm -rf -- "$directory"
  SF_REQUEST[directory]=''
}
