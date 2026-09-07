# jq resolves a relative module name against the working directory, ahead of any
# -L, so an installed Shellfish invoked inside a checkout would load that
# checkout's modules. Standing in the installation is therefore what makes the
# repository-rooted module names resolve, and -L adds nothing. Redirections still
# resolve in the caller's directory, since the caller sets them up before the
# subshell moves; file arguments passed to jq must be absolute.
sf_jq() (
  builtin cd -- "$SF_ROOT" || return
  jq "$@"
)
