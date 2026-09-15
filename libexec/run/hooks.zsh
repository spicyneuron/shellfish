emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_hooks_run] )) || source "$SF_ROOT/lib/hooks.zsh"

sf_hooks_user_prompt_submit() {
  sf_hooks_run "$1" user_prompt_submit "$2" allow 1 1 || return
  reply=(proceed)
}
