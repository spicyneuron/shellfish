emulate -R zsh
setopt no_aliases pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"

# Decodes common producer state and returns any remaining control followed by
# canonical state records. Empty remaining control means state was the only key.
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
    include "lib/runtime/schema";
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
