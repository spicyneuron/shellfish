emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/chat/render/nodes.zsh"
source "$SF_ROOT/lib/chat/render/highlights.zsh"
source "$SF_ROOT/lib/chat/render/rows.zsh"
source "$SF_ROOT/lib/chat/render/viewport.zsh"
source "$SF_ROOT/lib/chat/render/terminal.zsh"
source "$SF_ROOT/lib/chat/render/view.zsh"
