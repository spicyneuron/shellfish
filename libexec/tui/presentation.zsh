emulate -R zsh
setopt no_aliases no_multios pipe_fail

# Theme and preview limits are current settings, not part of a frozen runtime,
# so they resolve from their own config on every run. Nothing here reaches the
# core: a session never carries presentation, and the runtime config never
# describes it.
(( $+functions[sf_jsonc_read] )) || source "$SF_ROOT/lib/jsonc.zsh"
(( $+functions[sf_cli_diagnostic] )) || source "$SF_ROOT/lib/cli.zsh"

typeset -g SF_PRESENTATION=''
typeset -g SF_PRESENTATION_ERROR=''
typeset -g SF_PRESENTATION_VERBOSE=0

sf_presentation_config_path() {
  local candidate=''
  if [[ -n ${XDG_CONFIG_HOME-} ]]; then
    candidate="$XDG_CONFIG_HOME/shellfish/tui.jsonc"
  elif [[ -n ${HOME-} ]]; then
    candidate="$HOME/.config/shellfish/tui.jsonc"
  fi
  if [[ -n $candidate ]]; then
    REPLY=${candidate:A}
  else
    REPLY=''
  fi
}

sf_presentation_fail() {
  SF_PRESENTATION_ERROR=$1
  return 1
}

sf_presentation_resolve() {
  local config_path defaults raw='{}' output
  local invalid_marker=': shellfish:invalid-config'
  local theme_marker=': shellfish:unknown-theme:'

  SF_PRESENTATION=''
  SF_PRESENTATION_ERROR=''
  sf_presentation_config_path
  config_path=$REPLY
  defaults=$(sf_jsonc_read "$SF_SHARE/default/tui.jsonc" 2>/dev/null) ||
    sf_presentation_fail 'invalid bundled TUI config' || return
  if [[ -n $config_path && ( -e $config_path || -L $config_path ) ]]; then
    [[ -f $config_path && -r $config_path ]] ||
      sf_presentation_fail "cannot read TUI config: $config_path" || return
    raw=$(sf_jsonc_read "$config_path" 2>&1) || {
      sf_cli_diagnostic "$raw"
      sf_presentation_fail "invalid TUI config: $config_path${REPLY:+: $REPLY}"
      return
    }
  fi

  output=$(jq -nce --argjson defaults "$defaults" --argjson raw "$raw" \
    -f "$SF_ROOT/libexec/tui/presentation.jq" 2>&1) || {
    if [[ $output == *"$theme_marker"* ]]; then
      sf_presentation_fail "unknown theme: ${output#*"$theme_marker"}"
    elif [[ $output == *"$invalid_marker" ]]; then
      sf_presentation_fail "invalid TUI config: $config_path"
    else
      sf_cli_diagnostic "$output"
      sf_presentation_fail \
        "invalid TUI config: ${config_path:-<defaults>}${REPLY:+: $REPLY}"
    fi
    return
  }
  SF_PRESENTATION=$output
  # --verbose widens previews for a stored session too.
  (( SF_PRESENTATION_VERBOSE )) || return 0
  SF_PRESENTATION=$(jq -c '.preview_lines_reasoning = "full" |
    .preview_lines = "full"' <<<"$output") ||
    sf_presentation_fail 'cannot apply verbose preview limits'
}
