emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

# Each entry is one action with NUL-joined fields. A batch is accepted whole or
# rejected whole, so an invalid line never leaves a partial turn on screen.
typeset -ga SF_PRESENT_ACTIONS=()
typeset -g SF_PRESENT_CONTEXT_WINDOW=''
typeset -g SF_TUI_PROJECT_MODE=live

# MODE is the record policy this batch starts in: "live" skips the durable
# records a client already rendered, "load" expands them.
sf_tui_project() {
  local mode=$1 projected record
  local -a fields
  shift
  SF_PRESENT_ACTIONS=()
  (( $# )) || return 0
  projected=$(printf '%s\n' "$@" | jq -jRn --arg mode "$mode" \
    --arg window "$SF_PRESENT_CONTEXT_WINDOW" \
    -f "$SF_ROOT/libexec/tui/project.jq" 2>/dev/null) || return 1
  [[ -z $projected ]] || SF_PRESENT_ACTIONS=( "${(@ps:\x1e:)${projected%$'\x1e'}}" )
  # Loading a session switches the record policy and refreshes the window that
  # later usage is measured against.
  SF_TUI_PROJECT_MODE=$mode
  for record in "${SF_PRESENT_ACTIONS[@]}"; do
    fields=( "${(@ps:\0:)record}" )
    case $fields[1] in
      session) SF_TUI_PROJECT_MODE=load ;;
      runtime) SF_PRESENT_CONTEXT_WINDOW=$fields[3] ;;
    esac
  done
}
