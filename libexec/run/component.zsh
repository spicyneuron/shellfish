emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"

typeset -gA SF_COMPONENT=()

# COMPONENT holds the template, the input, and the draft a client shows while the
# component runs. A draft with no text claims no row.
sf_run_component_begin() {
  SF_COMPONENT=( session "$1" values "$2" error '' )
  sf_run_component_draft "$2"
}

sf_run_component_draft() {
  local draft
  draft=$(jq -c '.draft | select(.user_text != "")' <<<"$1") || return 1
  [[ -z $draft ]] || sf_run_emit "$draft"
}

# One fd 3 line. Its state updates are durable at once. Any trailing KEYs pass
# through unvalidated, as JSON in REPLY when present.
sf_run_component_line() {
  local record
  local -A line
  [[ -z $SF_COMPONENT[error] ]] || return 1
  sf_jq_fields -cR '
      include "lib/fields";
      include "lib/session";
      (try fromjson catch null) as $line |
      if $line | type == "object" and
        ((keys - ["state_update"] - $ARGS.positional) | length == 0) and
        ((has("state_update") | not) or (.state_update | type == "array" and
          all(.[]; type == "object" and ({type:"state_update"} + . | canonical_state_update))))
      then
        entry("state_updates"; [$line.state_update[]? | {type:"state_update"} + . | tojson] |
          join("\n")),
        entry("rest"; $line | del(.state_update) | if . == {} then "" else tojson end),
        ("ok" | field)
      else error("invalid component line") end
    ' --args "${@:2}" <<<"$1" || { SF_COMPONENT[error]=invalid; return 1; }
  line=( "${reply[@]}" )
  for record in ${(f)line[state_updates]}; do
    sf_run_append "$SF_COMPONENT[session]" "$record" ||
      { SF_COMPONENT[error]=$REPLY; return 1; }
  done
  REPLY=$line[rest]
}

# Run a prepared command into CAPTURE, streaming fd 3 lines of at most
# MAX_CONTROL bytes to the supplied handler. reply is (status exit_code) with
# status ok, interrupted, invalid, or overflow; ok leaves the bounded outcome in
# REPLY. Failure leaves a message in REPLY.
sf_run_component_execute() {
  local capture=$1 limit=$4 max_control=$5 state=ok
  local -A process
  sf_process_run "$@" ||
    { REPLY=$SF_PROCESS_ERROR; return 1; }
  process=( "${reply[@]}" )
  if (( process[interrupted] )); then
    state=interrupted
  elif [[ $SF_COMPONENT[error] == invalid ]]; then
    state=invalid
  elif [[ -n $SF_COMPONENT[error] ]]; then
    REPLY=$SF_COMPONENT[error]
    return 1
  elif (( process[control_bytes] > max_control )); then
    state=overflow
  else
    sf_run_component_bound "$capture/stdout" "$capture/stdout.bounded" "$limit" &&
      sf_run_component_bound "$capture/stderr" "$capture/stderr.bounded" "$limit" &&
      REPLY=$(jq -cn --rawfile stdout "$capture/stdout.bounded" \
        --rawfile stderr "$capture/stderr.bounded" --argjson exit_code "$process[exit_code]" '
        {output:{stdout:$stdout,stderr:$stderr,exit_code:$exit_code},ran:true}') ||
      { REPLY='cannot capture component output'; return 1; }
  fi
  reply=( $state $process[exit_code] )
}

sf_run_component_bound() {
  local source=$1 destination=$2
  integer limit=$3 bytes room
  local marker=$'[output truncated]\n'
  bytes=$(wc -c <"$source") || return
  if (( bytes <= limit )); then
    cat "$source" >"$destination"
  else
    room=$(( limit - ${#marker} ))
    print -rn -- "$marker" >"$destination" && tail -c "$room" "$source" >>"$destination"
  fi
}
