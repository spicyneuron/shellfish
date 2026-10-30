emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Each entry is one action with NUL-joined fields. A batch is accepted whole or
# rejected whole, so an invalid line never leaves a partial turn on screen.
typeset -ga SF_PRESENT_ACTIONS=()
typeset -g SF_PRESENT_CONTEXT_WINDOW=''
typeset -g SF_TUI_PROJECT_MODE=live
typeset -g SF_TUI_PROJECT_DRAWN=null

# MODE is the record policy this batch starts in: "load" adds replay-only
# content such as the system text and prompt history.
sf_tui_project() {
  local mode=$1 projected
  local -a state
  shift
  SF_PRESENT_ACTIONS=()
  (( $# )) || return 0
  projected=$(printf '%s\n' "$@" | jq -jRn --arg mode "$mode" \
    --arg window "$SF_PRESENT_CONTEXT_WINDOW" --argjson drawn "$SF_TUI_PROJECT_DRAWN" \
    -f "$SF_ROOT/libexec/tui/project.jq" 2>/dev/null) || return 1
  # The batch's final state leads: record policy, context window, live drawing.
  state=( "${(@ps:\0:)${projected%%$'\x1e'*}}" )
  projected=${projected#*$'\x1e'}
  [[ -z $projected ]] || SF_PRESENT_ACTIONS=( "${(@ps:\x1e:)${projected%$'\x1e'}}" )
  SF_TUI_PROJECT_MODE=$state[1]
  SF_PRESENT_CONTEXT_WINDOW=$state[2]
  SF_TUI_PROJECT_DRAWN=$state[3]
}
