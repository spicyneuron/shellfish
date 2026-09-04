emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_tui_repaint] )) || source "$SF_ROOT/tui/render/main.zsh"
(( $+functions[sf_tui_transport_start] )) || source "$SF_ROOT/tui/transport.zsh"
(( $+functions[sf_tui_bind] )) || source "$SF_ROOT/tui/editor.zsh"
(( $+functions[sf_tui_controller] )) || source "$SF_ROOT/tui/controller.zsh"

sf_tui_run() {
  local session=$1 runtime=$2 session_mode=$3
  integer clear_requested=${4:-0}
  local initial_prompt=${5-} draft=${6-}
  integer controller_status=0

  SF_TUI_ERROR=''
  typeset -gx SHELLFISH_MODE=chat
  SF_TUI_TRANSPORT_COMMAND=( "$SF_ENTRY" exec --jsonl --session "$session" )
  if (( clear_requested )); then
    zmodload zsh/terminfo && echoti clear || {
      SF_TUI_ERROR='cannot clear terminal'
      return 1
    }
  fi
  sf_tui_controller "$session" "$runtime" "$initial_prompt" "$session_mode" "$draft" ||
    controller_status=$?
  if (( controller_status )); then
    SF_TUI_ERROR=$SF_PRESENT_ERROR
    return $controller_status
  fi
}
