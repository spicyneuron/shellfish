emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_scratch_file] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -gA SF_REQUEST=(
  assistant '' error '' error_file '' partial_events '' pid ''
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
  local error_file adapter_pid adapter_status event decoded kind=''
  local -a events
  # Text and reasoning deltas share one sequence so clients can distinguish a
  # response start from a mid-response join.
  integer delta_seq=0 ended=0

  SF_REQUEST[assistant]=''
  SF_REQUEST[error]=''
  SF_REQUEST[error_file]=''
  SF_REQUEST[partial_events]=''
  SF_REQUEST[pid]=''
  sf_scratch_file backends exec-error || {
    SF_REQUEST[error]='cannot prepare provider error capture'
    return 1
  }
  error_file=$REPLY
  SF_REQUEST[error_file]=$error_file
  coproc SHELLFISH_API_KEY="$api_key" SHELLFISH_API_KEY_SOURCE="$api_key_source" \
    "$command" <<<"$request" 2>"$error_file"
  adapter_pid=$!
  SF_REQUEST[pid]=$adapter_pid
  "$emit" '{"type":"_backend_request_start"}'
  while IFS= read -r event <&p; do
    decoded=$(jq -L "$SF_ROOT" -cr --argjson seq "$delta_seq" '
      include "lib/runtime/schema";
      if canonical_backend_event | not then "invalid"
      elif .type == "_assistant_delta" or .type == "_assistant_reasoning_delta" then
        "delta", (.seq = $seq)
      elif .type == "_assistant_reasoning_opaque" then "opaque"
      elif .type == "_turn_usage" then "usage"
      elif .type == "_assistant_response_end" then "end"
      else "internal" end
    ' <<<"$event" 2>/dev/null) || decoded=invalid
    kind=${decoded%%$'\n'*}
    (( ! ended )) || kind=invalid
    case $kind in
      delta|opaque)
        events+=( "$event" )
        [[ -z $SF_REQUEST[partial_events] ]] || SF_REQUEST[partial_events]+=$'\n'
        SF_REQUEST[partial_events]+=$event
        if [[ $kind == delta ]]; then
          "$emit" "${decoded#*$'\n'}"
          (( ++delta_seq ))
        fi
        ;;
      usage)
        events+=( "$event" )
        "$emit" "$event"
        ;;
      internal) events+=( "$event" ) ;;
      end)
        events+=( "$event" )
        ended=1
        ;;
      *) kind=invalid; break ;;
    esac
  done
  if [[ $kind == invalid ]]; then
    sf_process_stop "$adapter_pid"
    adapter_status=1
  elif wait "$adapter_pid"; then adapter_status=0
  else adapter_status=$?
  fi
  SF_REQUEST[pid]=''
  if [[ $kind != invalid && $adapter_status == 0 ]] && (( ended )); then
    SF_REQUEST[assistant]=$(printf '%s\n' "${events[@]}" | jq -L "$SF_ROOT" -cse '
      include "lib/runtime/schema";
      assemble_backend_response
    ' 2>/dev/null) || kind=invalid
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
