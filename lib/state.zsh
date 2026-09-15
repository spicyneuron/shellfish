emulate -R zsh
setopt no_aliases no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

# Return remaining control in REPLY and canonical state records in reply.
sf_state_control_decode() {
  local capture=$1 control output
  REPLY=''
  reply=()

  control=$(jq -cse '
    if length == 1 and (.[0] | type == "object") then .[0]
    else error("expected one object") end
  ' "$capture" 2>/dev/null) || {
    REPLY=malformed
    return 1
  }
  output=$(sf_jq -jnre --argjson control "$control" '
    include "lib/session/read";
    def field: ., "\u0000";
    if $control | if has("state") then
        .state | type == "array" and all(.[];
          type == "object" and keys == ["name", "value"] and
          ({type:"state"} + . | canonical_state))
      else true end
    then
      ($control |
        if has("state") then
          del(.state) | if length == 0 then "" else tojson end
        else tojson end | field),
      ($control.state[]? | {type:"state"} + . | tojson | field)
    else error("invalid state control") end
  ' 2>/dev/null) || {
    REPLY=state
    return 1
  }
  reply=( "${(@0)${output%$'\0'}}" )
}
