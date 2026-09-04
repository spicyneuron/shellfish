emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_prepare] )) || source "$SF_ROOT/lib/session/main.zsh"
(( $+functions[sf_hooks_session_start] )) || source "$SF_ROOT/lib/hooks.zsh"
(( $+functions[sf_runtime_resolve] )) || source "$SF_ROOT/lib/runtime/main.zsh"

typeset -g SF_SESSION_STARTUP_ERROR=''
typeset -gA SF_SESSION_OPEN=( path '' presentation '' mode '' )

# Resolves what a client needs to attach to a session: its path, the current
# presentation, and whether the transcript already existed or was created here.
# The frozen runtime stays in the transcript; clients read it from there.
sf_session_open() {
  local requested=$1 config=$2 profile=$3 model=$4 request=$5 backend=$6
  integer override=$7 continue_requested=$8
  local source_session=$9 runtime
  integer runtime_status=0

  SF_SESSION_STARTUP_ERROR=''
  SF_SESSION_OPEN=( path '' presentation '' mode resume )

  if (( continue_requested )); then
    sf_session_find 1 || {
      SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
      return 1
    }
    requested=$SF_SESSION_MATCHES[1]
  fi
  sf_session_select_path "$requested" || {
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
    return 1
  }
  SF_SESSION_OPEN[path]=$REPLY
  if [[ ! -s $REPLY ]]; then
    [[ ! -e $REPLY || ( -f $REPLY && ! -L $REPLY ) ]] || {
      SF_SESSION_STARTUP_ERROR="invalid session path: $REPLY"
      return 1
    }
    SF_SESSION_OPEN[mode]=startup
  fi

  if [[ $SF_SESSION_OPEN[mode] == resume ]]; then
    sf_runtime_resolve "$SF_SESSION_OPEN[path]" "$config" "$profile" "$model" \
      "$request" "$backend" "$override" || runtime_status=$?
    if (( runtime_status )); then
      SF_SESSION_STARTUP_ERROR=$SF_RUNTIME_ERROR
      return $runtime_status
    fi
    SF_SESSION_OPEN[presentation]=$SF_PRESENTATION
    return 0
  fi

  if [[ -n $source_session ]]; then
    sf_session_read_settings "$source_session" || {
      SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
      return 1
    }
    runtime=$REPLY
    sf_runtime_restore_presentation "$config" || {
      SF_SESSION_STARTUP_ERROR=$SF_RUNTIME_ERROR
      return 1
    }
  else
    sf_runtime_resolve '' "$config" "$profile" "$model" "$request" "$backend" "$override" || {
      SF_SESSION_STARTUP_ERROR=$SF_RUNTIME_ERROR
      return 1
    }
    runtime=$REPLY
  fi
  SF_SESSION_OPEN[presentation]=$SF_PRESENTATION
  sf_session_startup_create "$SF_SESSION_OPEN[path]" "$runtime"
}

sf_session_startup_create() {
  local session=$1 runtime=$2
  SF_SESSION_STARTUP_ERROR=''
  SF_SESSION_PATH=$session
  SHELLFISH_SESSION_STATE=''
  if ! sf_hooks_session_state_create; then
    SF_SESSION_STARTUP_ERROR=$SF_HOOK_ERROR
  elif ! sf_session_prepare "$runtime"; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  elif ! sf_session_system; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  elif ! sf_hooks_session_start "$session"; then
    SF_SESSION_STARTUP_ERROR=$SF_HOOK_ERROR
  elif ! sf_session_create "${SF_HOOK_CONTEXT_RECORDS[@]}"; then
    SF_SESSION_STARTUP_ERROR=$SF_SESSION_ERROR
  fi
  [[ -z $SF_SESSION_STARTUP_ERROR ]]
}
