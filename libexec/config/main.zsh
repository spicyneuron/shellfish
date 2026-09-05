#!/usr/bin/env zsh

emulate -R zsh
setopt no_aliases no_multios pipe_fail

typeset -gr SF_ROOT=${0:A:h:h:h}
typeset -gr SF_SHARE=$SF_ROOT/share

sf_die() {
  print -u2 -r -- "shellfish: $*"
  return 1
}

sf_config_main() {
  local requested_config='' requested_session='' requested_profile=''
  local requested_backend='' requested_model='' requested_request='{}'
  local sandbox_detected='{"sandbox_read_paths":[],"sandbox_write_paths":[]}'
  local sandbox_flag sandbox_path resolved_path init_sandbox=''
  local -a sandbox_read_paths=() sandbox_write_paths=()
  integer session_explicit=0 config_explicit=0 request_explicit=0 runtime_override=0
  integer init_requested=0 verbose_requested=0 sandbox_auto_requested=0

  while (( $# )); do
    case $1 in
      --init)
        init_requested=1
        shift
        ;;
      --verbose)
        verbose_requested=1
        shift
        ;;
      --sandbox-auto)
        sandbox_auto_requested=1
        shift
        ;;
      --config)
        (( ! config_explicit )) || { sf_die '--config may only be specified once'; return 2; }
        [[ -n $2 && $2 != - ]] ||
          { sf_die '--config requires a nonempty file path other than -'; return 2; }
        config_explicit=1
        requested_config=$2
        shift 2
        ;;
      --session)
        (( ! session_explicit )) || { sf_die '--session may only be specified once'; return 2; }
        [[ -n $2 ]] || { sf_die '--session requires a nonempty path'; return 2; }
        session_explicit=1
        requested_session=$2
        shift 2
        ;;
      -p|--profile)
        [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
          { sf_die '--profile must match [A-Za-z0-9][A-Za-z0-9_-]*'; return 2; }
        requested_profile=$2
        runtime_override=1
        shift 2
        ;;
      -m|--model)
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] ||
          { sf_die '--model requires a nonempty value without control characters'; return 2; }
        requested_model=$2
        runtime_override=1
        shift 2
        ;;
      -b|--backend)
        [[ -n $2 && ! $2 =~ '[[:cntrl:]]' ]] ||
          { sf_die '--backend requires a nonempty value without control characters'; return 2; }
        requested_backend=$2
        runtime_override=1
        shift 2
        ;;
      --request)
        (( ! request_explicit )) || { sf_die '--request may only be specified once'; return 2; }
        requested_request=$(jq -ce 'select(type == "object")' <<<"$2" 2>/dev/null) ||
          { sf_die '--request requires a JSON object'; return 2; }
        request_explicit=1
        runtime_override=1
        shift 2
        ;;
      --sandbox-read|--sandbox-write)
        sandbox_flag=$1
        [[ -n $2 ]] || { sf_die "$sandbox_flag requires a nonempty path"; return 2; }
        sandbox_path=$2
        if [[ $sandbox_path == '~/'* ]]; then
          [[ -n ${HOME-} ]] || { sf_die "$sandbox_flag cannot expand ~ without HOME"; return 2; }
          sandbox_path="$HOME/${sandbox_path#\~/}"
        elif [[ $sandbox_path != /* ]]; then
          sandbox_path="$PWD/$sandbox_path"
        fi
        resolved_path=${sandbox_path:A}
        [[ -e $resolved_path ]] || { sf_die "$sandbox_flag path does not exist: $2"; return 2; }
        if [[ $sandbox_flag == --sandbox-read ]]; then
          sandbox_read_paths+=( "$resolved_path" )
        else
          sandbox_write_paths+=( "$resolved_path" )
        fi
        runtime_override=1
        shift 2
        ;;
      --)
        shift
        (( ! $# )) || { sf_die 'shellfish config does not accept a prompt'; return 2; }
        ;;
      -*)
        sf_die "unknown argument: $1"
        return 2
        ;;
      *)
        sf_die 'shellfish config does not accept a prompt'
        return 2
        ;;
    esac
  done

  if (( init_requested )); then
    (( ! session_explicit && ! verbose_requested && ! request_explicit )) &&
      [[ -z $requested_profile && -z $requested_backend && -z $requested_model ]] || {
      sf_die '--init only supports --config and sandbox flags'
      return 2
    }
  fi

  (( $+commands[jq] )) || {
    sf_die 'shellfish requires jq'
    return 2
  }
  source "$SF_ROOT/libexec/config/runtime.zsh"
  source "$SF_ROOT/libexec/config/init.zsh"
  if (( sandbox_auto_requested )); then
    source "$SF_ROOT/libexec/config/sandbox.zsh"
    sandbox_detected=$(sf_sandbox_detect) || {
      sf_die 'cannot detect sandbox paths'
      return 1
    }
  fi
  # Explicit grants precede detected ones. Read paths are passed before write
  # paths, so their count splits the positional arguments.
  SF_RUNTIME_SANDBOX_GRANTS=$(jq -cn --argjson detected "$sandbox_detected" \
    --argjson reads "${#sandbox_read_paths}" --args '
      {sandbox_read_paths: ($ARGS.positional[:$reads] + $detected.sandbox_read_paths),
       sandbox_write_paths: ($ARGS.positional[$reads:] + $detected.sandbox_write_paths)}
    ' -- "${sandbox_read_paths[@]}" "${sandbox_write_paths[@]}") || return 1

  if (( init_requested )); then
    if (( sandbox_auto_requested || ${#sandbox_read_paths} || ${#sandbox_write_paths} )); then
      init_sandbox=$SF_RUNTIME_SANDBOX_GRANTS
    fi
    sf_config_init "$requested_config" "$init_sandbox" || {
      sf_die "$SF_CONFIG_ERROR"
      return 1
    }
    print -r -- "Initialized config: $REPLY"
    return
  fi

  source "$SF_ROOT/lib/session/main.zsh"
  SF_RUNTIME_VERBOSE=$verbose_requested
  (( ! sandbox_auto_requested )) || runtime_override=1
  sf_runtime_resolve "$requested_session" "$requested_config" \
    "$requested_profile" "$requested_model" "$requested_request" \
    "$requested_backend" "$runtime_override" || {
    local resolve_status=$?
    sf_die "$SF_RUNTIME_ERROR"
    return $resolve_status
  }
  sf_runtime_report "$REPLY"
}

sf_config_main "$@"
typeset exit_status=$?
exit $exit_status
