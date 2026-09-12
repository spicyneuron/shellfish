# Resolve relative jq modules from the installation, not the caller.
# Caller redirections retain their paths; jq file arguments must be absolute.
sf_jq() (
  builtin cd -- "$SF_ROOT" || return
  jq "$@"
)
