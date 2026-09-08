#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_ENTRY="$SF_ROOT/bin/shellfish"
typeset -g SF_CREATE_JSONL=0

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_create_emit() {
  (( SF_CREATE_JSONL )) && print -r -- "$1" || true
}

sf_create_interrupt() {
  local exit_status=$1
  sf_process_capture_stop
  rm -f -- "$SF_SESSION_PATH" 2>/dev/null
  exit $exit_status
}

sf_create_session() {
  local session=$1 runtime=$2 system=$3 error=''
  local SF_HOOK_JSONL=$SF_CREATE_JSONL
  typeset -gx SHELLFISH_MODE=create
  SF_SESSION_PATH=$session
  if ! sf_session_prepare "$runtime"; then
    sf_die "$SF_SESSION_ERROR"
    return 1
  elif ! sf_session_system "$system"; then
    sf_die "$SF_SESSION_ERROR"
    return 1
  fi
  printf '%s\n' "${SF_SESSION_RECORDS[@]}" |
    "$SF_ENTRY" install-session --session-out "$session" >/dev/null || return 1
  if (( SF_CREATE_JSONL )) && ! printf '%s\n' "${SF_SESSION_RECORDS[@]}" | jq -cs \
      --arg path "$session" '{type:"_session_prepare",path:$path,records:.}'; then
    sf_die 'cannot emit session preparation'
    return 1
  elif ! sf_hooks_session_start "$session"; then
    error=$SF_HOOK_ERROR
  elif ! sf_hooks_commit sf_create_emit; then
    error=$SF_HOOK_ERROR
  fi
  [[ -n $error ]] || return 0
  rm -f -- "$session" 2>/dev/null
  sf_session_reset
  sf_die "$error"
  return 1
}

sf_create_main() {
  local requested_out='' report runtime session system
  local -a forwarded=()
  integer report_status=0 take=0
  source "$SF_ROOT/lib/options.zsh"

  while (( $# )); do
    case $1 in
      --jsonl)
        SF_CREATE_JSONL=1
        shift
        ;;
      --session-out)
        [[ -z $requested_out ]] || { sf_die '--session-out may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session-out requires a nonempty path'; return 2; }
        requested_out=$2
        shift 2
        ;;
      *)
        # Forward option values with their option so that a value that looks
        # like --session-out is not read as one.
        take=$(( ${SF_CONFIG_OPTIONS[$1]:-0} + 1 ))
        (( $# >= take )) || { sf_die "$1 requires a value"; return 2; }
        forwarded+=( "${@:1:$take}" )
        shift $take
        ;;
    esac
  done

  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  # Configuration resolution belongs to shellfish config, including its rejection
  # of runtime overrides against --session-from.
  report=$("$SF_ENTRY" config "${forwarded[@]}") || report_status=$?
  (( ! report_status )) || return $report_status
  runtime=$(jq -ce 'del(.theme, .tui, .system)' <<<"$report") || {
    sf_die 'cannot resolve the session runtime'
    return 1
  }
  system=$(jq -j '.system + "\u0000"' <<<"$report") || {
    sf_die 'cannot resolve the system prompt'
    return 1
  }
  system=${system%$'\0'}

  source "$SF_ROOT/lib/session/main.zsh"
  source "$SF_ROOT/lib/hooks.zsh"
  source "$SF_ROOT/lib/process.zsh"
  # USR1 is the client's cancellation signal, aimed at this process alone.
  trap 'sf_create_interrupt 130' INT USR1
  trap 'sf_create_interrupt 129' HUP
  trap 'sf_create_interrupt 143' TERM
  sf_session_select_path "$requested_out" || {
    sf_die "$SF_SESSION_ERROR"
    return 1
  }
  session=$REPLY
  sf_create_session "$session" "$runtime" "$system" || return 1
  if (( SF_CREATE_JSONL )); then
    jq -cn --arg path "$session" '{type:"_session_created",path:$path}' || return 1
  else
    print -r -- "$session" || return 1
  fi
}

sf_create_main "$@"
typeset exit_status=$?
exit $exit_status
