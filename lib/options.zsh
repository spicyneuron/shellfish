# Options that clients forward to session creation. Each takes one value.
# --verbose remains owned by its parsing client.
typeset -ga SF_CREATE_OPTIONS=(
  --session-from -p --profile -m --model --sandbox --system
  -t --tool --command --hook
)
