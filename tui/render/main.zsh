emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_tui_event] )) || source "$SF_ROOT/tui/render/nodes.zsh"
(( $+functions[sf_tui_highlight_update] )) || source "$SF_ROOT/tui/render/highlights.zsh"
(( $+functions[sf_tui_rows] )) || source "$SF_ROOT/tui/render/rows.zsh"
(( $+functions[sf_tui_viewport] )) || source "$SF_ROOT/tui/render/viewport.zsh"
(( $+functions[sf_tui_terminal_reset] )) || source "$SF_ROOT/tui/render/terminal.zsh"
(( $+functions[sf_tui_repaint] )) || source "$SF_ROOT/tui/render/view.zsh"
