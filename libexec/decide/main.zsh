#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
integer -gr SF_DECIDE_CAPTURE=$(( 1024 * 1024 ))

source "$SF_ROOT/lib/cli.zsh"

sf_decide_main() {
  local decision result error
  local -a models=()
  local -A process
  integer resolve_status
  while (( $# )); do
    case $1 in
      -m|--model)
        [[ -n $2 ]] || { sf_die "$1 requires a reference or JSON object"; return 2; }
        models+=( "$2" )
        shift 2
        ;;
      *) sf_die "unknown argument: $1"; return 2 ;;
    esac
  done
  (( ${#models} )) || { sf_die 'decide requires --model'; return 2; }
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  source "$SF_ROOT/lib/backend.zsh"
  source "$SF_ROOT/lib/profile.zsh"
  decision=$(sf_jq -sc '
    include "lib/backend";
    if length == 1 then .[0] | decision_request else error("expected one JSON object") end
  ' 2>&1) || {
    sf_cli_diagnostic "$decision"
    sf_die "invalid decision request: $REPLY"
    return 2
  }
  sf_profile_model_refs decide "${models[@]}" || {
    resolve_status=$?
    sf_die "$SF_PROFILE_ERROR"
    return $resolve_status
  }
  # Inline media can exceed argument limits, so the decision travels on stdin.
  sf_jq_fields -c --argjson model "$REPLY" '
    include "lib/fields";
    include "lib/backend";
    entry("request"; decision_adapter_request($model; .) | tojson),
    entry("command"; $model.adapter + "/decide"),
    ("ok" | field)
  ' <<<"$decision" || { sf_die 'cannot prepare decision request'; return 1; }
  SF_BACKEND_PLAN=( "${reply[@]}" cwd "${PWD:A}" )

  sf_backend_capture "$SF_BACKEND_PLAN[command]" $SF_DECIDE_CAPTURE || {
    sf_die "$SF_BACKEND[error]"
    return 1
  }
  process=( "${reply[@]}" )
  (( ! process[interrupted] )) || return $process[interrupted]
  if (( process[exit_code] )); then
    error=$(print -rn -- "$process[stderr]" | LC_ALL=C tr -s '[:cntrl:]' ' ' | cut -c 1-1000)
    sf_die "${error:-backend exited before completing a decision}"
    return 1
  fi
  (( process[stdout_bytes] <= SF_DECIDE_CAPTURE )) &&
    result=$(print -rl -- "$decision" "$process[stdout]" | sf_jq -sce '
      include "lib/session";
      include "lib/backend";
      .[0].questions as $questions | .[1:] |
      select(length == 1) | .[0] |
      select(decision_result($questions) and
        ((has("usage") | not) or (.usage | token_usage)))
    ' 2>/dev/null) || {
    sf_die 'backend returned an invalid decision'
    return 1
  }
  print -r -- "$result"
}

sf_decide_main "$@"
typeset exit_status=$?
exit $exit_status
