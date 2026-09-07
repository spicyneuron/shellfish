# jq resolves a relative module name against the working directory before it
# consults -L, so an installed Shellfish invoked inside a checkout would load
# that checkout's modules. Redirections still resolve in the caller's directory,
# since the caller sets them up before the subshell moves; file arguments passed
# to jq must be absolute.
sf_jq() (
  builtin cd -- "$SF_ROOT" || return
  jq -L "$SF_ROOT" "$@"
)
