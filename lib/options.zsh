# Arity of the options shellfish config owns, so that a component forwarding
# them while also accepting a bare prompt can tell an option value from the
# prompt instead of guessing. Values count the tokens each option takes.
#
# config also owns --init, --verbose, and --session. They are absent because a
# forwarding component either owns them itself or must not pass them on.

typeset -gA SF_CONFIG_OPTIONS=(
  --config 1 -p 1 --profile 1 -m 1 --model 1 -b 1 --backend 1
  --request 1 --sandbox-read 1 --sandbox-write 1
  --sandbox-auto 0
)
