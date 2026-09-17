# Resolve relative jq modules from the installation, not the caller.
# Caller redirections retain their paths; jq file arguments must be absolute.
sf_jq() (
  builtin cd -- "$SF_ROOT" || return
  jq "$@"
)

# Decode a NUL-terminated field projection into reply. The program must end
# with an "ok" field, so a program that failed partway cannot pass; a positive
# arity also asserts the field count.
sf_jq_fields() {
  integer arity=$1
  local projection
  shift
  projection=$(sf_jq -j "$@" 2>/dev/null) || return 1
  reply=( "${(@0)${projection%$'\0'}}" )
  [[ $reply[-1] == ok ]] || return 1
  (( ! arity || ${#reply} == arity + 1 )) || return 1
  reply=( "${(@)reply[1,-2]}" )
}
