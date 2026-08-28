emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_chat_event] )) || source "$SF_ROOT/lib/chat/render/nodes.zsh"
(( $+functions[sf_chat_highlight_update] )) || source "$SF_ROOT/lib/chat/render/highlights.zsh"
(( $+functions[sf_chat_rows] )) || source "$SF_ROOT/lib/chat/render/rows.zsh"
(( $+functions[sf_chat_viewport] )) || source "$SF_ROOT/lib/chat/render/viewport.zsh"
(( $+functions[sf_chat_terminal_reset] )) || source "$SF_ROOT/lib/chat/render/terminal.zsh"
(( $+functions[sf_chat_repaint] )) || source "$SF_ROOT/lib/chat/render/view.zsh"
