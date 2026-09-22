emulate -R zsh
setopt no_aliases no_multios pipe_fail

# Theme and preview limits are current settings, not part of a frozen runtime,
# so they resolve from config on every run. The shared runtime supplies only
# config reading and error formatting, both of which report SF_RUNTIME_ERROR.
(( $+functions[sf_runtime_load_config] )) || source "$SF_ROOT/lib/runtime.zsh"

typeset -g SF_PRESENTATION=''
typeset -g SF_PRESENTATION_ERROR=''
typeset -g SF_PRESENTATION_VERBOSE=0

sf_presentation_resolve() {
  local requested_config=$1 config_path defaults raw output
  local invalid_marker=': shellfish:invalid-config'
  local theme_marker=': shellfish:unknown-theme:'
  local -a loaded

  SF_PRESENTATION=''
  SF_PRESENTATION_ERROR=''
  sf_runtime_load_config "$requested_config" || {
    SF_PRESENTATION_ERROR=$SF_RUNTIME_ERROR
    return 1
  }
  loaded=( "${reply[@]}" )
  config_path=$loaded[1]
  defaults=$loaded[2]
  raw=$loaded[3]
  output=$(jq -nce --argjson defaults "$defaults" --argjson raw "$raw" \
    -f "$SF_ROOT/libexec/tui/presentation.jq" 2>&1) || {
    if [[ $output == *"$theme_marker"* ]]; then
      SF_PRESENTATION_ERROR="unknown theme: ${output#*"$theme_marker"}"
    elif [[ $output == *"$invalid_marker" ]]; then
      SF_PRESENTATION_ERROR="invalid config: $config_path"
    else
      sf_runtime_validation_error "$output" \
        "invalid presentation config: ${config_path:-<defaults>}"
      SF_PRESENTATION_ERROR=$SF_RUNTIME_ERROR
    fi
    return 1
  }
  SF_PRESENTATION=$output
  # --verbose widens previews for a stored session too.
  (( SF_PRESENTATION_VERBOSE )) || return 0
  SF_PRESENTATION=$(jq -c '.tui.preview_lines_reasoning = "full" |
    .tui.preview_lines = "full"' <<<"$output") || {
    SF_PRESENTATION_ERROR='cannot apply verbose preview limits'
    return 1
  }
}
