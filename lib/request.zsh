emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_scratch_file] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -gA SF_REQUEST=(
  assistant '' error '' error_file '' partial_events '' pid '' result '' status_file ''
)

sf_request_build() {
  local runtime=$1 tools=$2
  jq -L "$SF_ROOT" -sce --argjson runtime "$runtime" --argjson tools "$tools" '
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

sf_process_stop() {
  local pid=$1 target=$1 watchdog
  [[ -n $pid ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null && target="-$pid" ||
    kill -TERM "$pid" 2>/dev/null || true
  kill -CONT -- "$target" 2>/dev/null || true
  {
    sleep 0.5
    kill -KILL -- "$target" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  } &
  watchdog=$!
  wait "$pid" 2>/dev/null || true
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

sf_request_run() {
  local request=$1 command=$2 api_key=$3 api_key_source=$4 emit=${5:-:}
  local error_file status_file response_pid event display kind=''
  integer process_status=0 adapter_status=1 decoder_status=1 ended=0

  SF_REQUEST[assistant]=''
  SF_REQUEST[error]=''
  SF_REQUEST[error_file]=''
  SF_REQUEST[partial_events]=''
  SF_REQUEST[pid]=''
  SF_REQUEST[result]=''
  SF_REQUEST[status_file]=''
  sf_scratch_file backends exec-error || {
    SF_REQUEST[error]='cannot prepare provider error capture'
    return 1
  }
  error_file=$REPLY
  SF_REQUEST[error_file]=$error_file
  sf_scratch_file backends response-status || {
    rm -f -- "$error_file"
    SF_REQUEST[error_file]=''
    SF_REQUEST[error]='cannot prepare provider status capture'
    return 1
  }
  status_file=$REPLY
  SF_REQUEST[status_file]=$status_file
  coproc {
    SHELLFISH_API_KEY="$api_key" SHELLFISH_API_KEY_SOURCE="$api_key_source" \
      "$command" <<<"$request" 2>"$error_file" |
      jq -L "$SF_ROOT" -jn --unbuffered '
        include "lib/runtime/schema";
        include "lib/request";
        decode_backend_response(canonical_backend_event; canonical_assistant_message)
      ' 2>/dev/null
    local -a child_statuses=( $pipestatus )
    print -r -- "$child_statuses[1] $child_statuses[2]" >"$status_file"
  }
  response_pid=$!
  SF_REQUEST[pid]=$response_pid
  "$emit" '{"type":"_backend_request_start"}'
  # Decoder metadata is NUL-framed; arbitrary stop text ends the response payload.
  while IFS= read -r -d $'\0' kind <&p; do
    case $kind in
      delta)
        if ! IFS= read -r -d $'\0' event <&p ||
            ! IFS= read -r -d $'\0' display <&p; then
          kind=invalid
          break
        fi
        [[ -z $SF_REQUEST[partial_events] ]] || SF_REQUEST[partial_events]+=$'\n'
        SF_REQUEST[partial_events]+=$event
        "$emit" "$display"
        ;;
      opaque)
        if ! IFS= read -r -d $'\0' event <&p; then
          kind=invalid
          break
        fi
        [[ -z $SF_REQUEST[partial_events] ]] || SF_REQUEST[partial_events]+=$'\n'
        SF_REQUEST[partial_events]+=$event
        ;;
      usage)
        if ! IFS= read -r -d $'\0' event <&p; then
          kind=invalid
          break
        fi
        "$emit" "$event"
        ;;
      end)
        SF_REQUEST[result]=$(<&p)
        ended=1
        break
        ;;
      *) kind=invalid; break ;;
    esac
  done
  if [[ $kind == invalid ]]; then
    sf_process_stop "$response_pid"
    process_status=1
  else
    wait "$response_pid" || process_status=$?
  fi
  SF_REQUEST[pid]=''
  if (( ! process_status )) &&
      read -r adapter_status decoder_status <"$status_file" 2>/dev/null &&
      [[ $adapter_status == <-> && $decoder_status == <-> ]]; then
    :
  else
    adapter_status=1
    decoder_status=1
  fi
  rm -f -- "$status_file"
  SF_REQUEST[status_file]=''
  (( decoder_status == 0 )) || kind=invalid
  if [[ $kind != invalid && $adapter_status == 0 ]] && (( ended )); then
    SF_REQUEST[assistant]=${SF_REQUEST[result]%%$'\0'*}
    [[ -z $SF_REQUEST[assistant] ]] || SF_REQUEST[partial_events]=''
  fi
  if [[ $kind == invalid || $adapter_status != 0 || -z $SF_REQUEST[assistant] ]]; then
    if [[ -s $error_file ]]; then
      SF_REQUEST[error]=$(LC_ALL=C tr -s '[:cntrl:]' ' ' <"$error_file" | cut -c 1-1000)
    elif [[ $kind == invalid ]]; then
      SF_REQUEST[error]='backend emitted an invalid event stream'
    else
      SF_REQUEST[error]='backend exited before completing a response'
    fi
    rm -f -- "$error_file"
    SF_REQUEST[error_file]=''
    return 1
  fi
  rm -f -- "$error_file"
  SF_REQUEST[error_file]=''
}
