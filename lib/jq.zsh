(( $+functions[sf_fail] )) || source "$SF_ROOT/lib/cli.zsh"

# Bundled data, which "@" names in references and stored profile paths.
[[ -n ${SF_SHARE-} ]] ||
  typeset -g SF_SHARE=$SF_ROOT/share

# Resolve relative jq modules from the installation, not the caller.
# Caller redirections retain their paths; jq file arguments must be absolute.
sf_jq() (
  builtin cd -- "$SF_ROOT" || return
  jq "$@"
)

# Decode a NUL-terminated field projection into reply. The program must end
# with an "ok" field, so a program that failed partway cannot pass. These
# programs only write to stderr when they fail, so one merged capture is either
# the projection or the diagnostic; on failure it lands in SF_ERROR.
sf_jq_fields() {
  local projection
  projection=$(sf_jq -j "$@" 2>&1) || { sf_fail "$projection"; return; }
  reply=( "${(@0)${projection%$'\0'}}" )
  [[ $reply[-1] == ok ]] || { sf_fail "$projection"; return; }
  reply=( "${(@)reply[1,-2]}" )
}
