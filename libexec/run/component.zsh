emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"

typeset -gA SF_COMPONENT=()

sf_run_component_begin() {
  SF_COMPONENT=( session "$1" values "$2" error '' live 0
    action '' reason '' payload '' )
  local draft
  draft=$(jq -c '.draft | select(.user_text != "")' <<<"$2") || return 1
  [[ -n $draft ]] || return 0
  sf_run_emit "$draft" && SF_COMPONENT[live]=1
}

# State is durable per valid line, while all presentation values stay transient.
sf_run_component_line() {
  local record
  local -A line
  [[ -z $SF_COMPONENT[error] ]] || return 0
  sf_jq_fields -cn --arg raw "$1" --argjson component "$SF_COMPONENT[values]" '
      include "lib/fields";
      include "lib/profile";
      include "lib/session";
      include "libexec/run/component";
      ($raw | try fromjson catch null | component_update($component) //
        error("invalid component line")) as $update |
      entry("states"; [$update.states[] | tojson] | join("\n")),
      entry("component"; $update.component | tojson),
      entry("draft"; $update.component.draft |
        if .user_text == $component.draft.user_text then "" else tojson end),
      entry("action"; $update.control.action // ""),
      entry("reason"; $update.control.reason // ""),
      entry("payload"; $update.control | (.argv // .profile) |
        if . == null then "" else tojson end),
      ("ok" | field)
    ' || { SF_COMPONENT[error]=invalid; return 1; }
  line=( "${reply[@]}" )
  for record in ${(f)line[states]}; do
    sf_run_append "$SF_COMPONENT[session]" "$record" ||
      { SF_COMPONENT[error]=$REPLY; return 1; }
  done
  SF_COMPONENT[values]=$line[component]
  if [[ -n $line[draft] ]]; then
    sf_run_emit "$line[draft]" ||
      { SF_COMPONENT[error]='cannot emit component draft'; return 1; }
    SF_COMPONENT[live]=1
  fi
  [[ -z $line[action] ]] || SF_COMPONENT+=( action "$line[action]"
    reason "$line[reason]" payload "$line[payload]" )
}

# Run a prepared command into CAPTURE, streaming fd 3 as component lines. reply
# is (status exit_code) with status ok, interrupted, invalid, or overflow; ok
# leaves the bounded outcome in REPLY. Failure leaves a message in REPLY.
sf_run_component_execute() {
  local capture=$1 limit=$4 state=ok
  local -A process
  sf_process_run "$@[1,4]" sf_run_component_line "$@[5,-1]" ||
    { REPLY=$SF_PROCESS_ERROR; return 1; }
  process=( "${reply[@]}" )
  if (( process[interrupted] )); then
    state=interrupted
  elif [[ $SF_COMPONENT[error] == invalid ]]; then
    state=invalid
  elif [[ -n $SF_COMPONENT[error] ]]; then
    REPLY=$SF_COMPONENT[error]
    return 1
  elif (( process[control_bytes] > limit )); then
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

sf_run_component_complete() {
  sf_jq_fields -cn --argjson component "$1" --argjson outcome "$2" '
    include "lib/fields";
    include "lib/session";
    include "lib/profile";
    include "libexec/run/component";
    component_result($component; $outcome) |
    if (if has("lifecycle") then canonical_hook_result else canonical_tool_result end) then
      entry("result"; if has("lifecycle") and .user_text == null and .model_text == null
        then "" else tojson end),
      entry("model_feedback"; .model_text != null | tostring), ("ok" | field)
    else error("invalid component result") end
  '
}

sf_run_component_clear() {
  (( SF_COMPONENT[live] )) || return 0
  local draft
  draft=$(jq -c '.draft + {user_text:""}' <<<"$SF_COMPONENT[values]") || return 1
  sf_run_emit "$draft" && SF_COMPONENT[live]=0
}

sf_run_component_bound() {
  local source=$1 destination=$2
  integer limit=$3 bytes room
  local marker=$'[output truncated]\n'
  bytes=$(wc -c <"$source") || return
  if (( bytes <= limit )); then
    cat "$source" >"$destination"
  elif (( limit <= ${#marker} )); then
    print -rn -- "${marker[1,limit]}" >"$destination"
  else
    room=$(( limit - ${#marker} ))
    print -rn -- "$marker" >"$destination" && tail -c "$room" "$source" >>"$destination"
  fi
}
