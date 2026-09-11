emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_tui_event] )) || source "$SF_ROOT/libexec/tui/render/formatters.zsh"
(( $+functions[sf_tui_theme_config] )) || source "$SF_ROOT/libexec/tui/render/highlights.zsh"
(( $+functions[sf_tui_cell_width] )) || source "$SF_ROOT/libexec/tui/render/text.zsh"
(( $+functions[sf_tui_wrap] )) || source "$SF_ROOT/libexec/tui/render/wrap.zsh"
(( $+functions[sf_tui_format_message] )) || source "$SF_ROOT/libexec/tui/render/messages.zsh"
(( $+functions[sf_tui_terminal_reset] )) || source "$SF_ROOT/libexec/tui/render/terminal.zsh"
(( $+functions[sf_tui_repaint] )) || source "$SF_ROOT/libexec/tui/render/view.zsh"
