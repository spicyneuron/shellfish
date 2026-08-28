emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail
zmodload zsh/system

(( $+functions[sf_runtime_resolve] )) || source "$SF_ROOT/lib/runtime/main.zsh"
(( $+functions[sf_session_select_path] )) || source "$SF_ROOT/lib/session/main.zsh"
(( $+functions[sf_hooks_session_start] )) || source "$SF_ROOT/lib/hooks.zsh"
source "$SF_ROOT/lib/session/startup.zsh"
source "$SF_ROOT/lib/chat/render/main.zsh"
source "$SF_ROOT/lib/chat/transport.zsh"
source "$SF_ROOT/lib/chat/editor.zsh"
source "$SF_ROOT/lib/chat/controller.zsh"

sf_chat_run() {
  local requested_session=${1-} requested_config=${2-} requested_profile=${3-}
  local requested_model=${4-} requested_request=${5:-\{\}} requested_backend=${6-}
  integer runtime_override=${7:-0} continue_requested=${8:-0} clear_requested=${9:-0}
  local initial_prompt=${10-} runtime session_mode=resume
  integer new_session=0
  integer controller_status=0 runtime_status=0

  SF_CHAT_ERROR=''
  typeset -gx SHELLFISH_MODE=chat
  if (( continue_requested )); then
    sf_session_find 1 || { SF_CHAT_ERROR=$SF_SESSION_ERROR; return 1; }
    requested_session=$SF_SESSION_MATCHES[1]
  fi

  sf_session_select_path "$requested_session" || {
    SF_CHAT_ERROR=$SF_SESSION_ERROR
    return 1
  }
  typeset -g SF_SESSION_SELECTED=$REPLY
  if [[ ! -s $SF_SESSION_SELECTED ]]; then
    [[ ! -e $SF_SESSION_SELECTED || ( -f $SF_SESSION_SELECTED && ! -L $SF_SESSION_SELECTED ) ]] || {
      SF_CHAT_ERROR="invalid session path: $SF_SESSION_SELECTED"
      return 1
    }
    new_session=1
    session_mode=startup
  fi
  if (( new_session )); then
    sf_runtime_resolve '' "$requested_config" "$requested_profile" \
      "$requested_model" "$requested_request" "$requested_backend" \
      "$runtime_override" || {
      SF_CHAT_ERROR=$SF_RUNTIME_ERROR
      return 1
    }
    runtime=$REPLY
    sf_session_startup_create "$SF_SESSION_SELECTED" "$runtime" \
      "$SF_RUNTIME_SYSTEM_RECORD" || {
      SF_CHAT_ERROR=$SF_SESSION_STARTUP_ERROR
      return 1
    }
  else
    sf_runtime_resolve "$SF_SESSION_SELECTED" "$requested_config" "$requested_profile" \
      "$requested_model" "$requested_request" "$requested_backend" "$runtime_override" ||
      runtime_status=$?
    if (( runtime_status )); then
      SF_CHAT_ERROR=$SF_RUNTIME_ERROR
      return $runtime_status
    fi
    runtime=$REPLY
  fi

  SF_CHAT_TRANSPORT_COMMAND=(
    "$SF_ENTRY" exec --jsonl --session "$SF_SESSION_SELECTED"
  )
  if (( clear_requested )); then
    zmodload zsh/terminfo && echoti clear || {
      SF_CHAT_ERROR='cannot clear terminal'
      return 1
    }
  fi
  sf_chat_controller "$SF_SESSION_SELECTED" "$runtime" "$initial_prompt" "$session_mode" ||
    controller_status=$?
  if (( controller_status )); then
    SF_CHAT_ERROR=$SF_PRESENT_ERROR
    return $controller_status
  fi
}
