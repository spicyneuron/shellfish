#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}

source "$SF_ROOT/lib/cli.zsh"

sf_request_main() {
  local model=null
  local -a models=()
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
  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }

  source "$SF_ROOT/lib/provider.zsh"
  if (( ${#models} )); then
    sf_profile_model_refs run "${models[@]}" || {
      local resolve_status=$?
      sf_die "$SF_ERROR"
      return $resolve_status
    }
    model=$REPLY
  fi
  sf_provider_project "$model" || { sf_die "$SF_ERROR"; return 1; }
  sf_provider_run || {
    local request_status=$?
    # A signal status means the request was cancelled, which needs no message.
    (( request_status != 1 )) || sf_die "$SF_ERROR"
    return $request_status
  }
  print -r -- "$REPLY"
}

sf_request_main "$@"
