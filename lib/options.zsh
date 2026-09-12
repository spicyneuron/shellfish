# Arity of the options accepted while creating a session, so that a component
# forwarding them beside a bare prompt never guesses whether the next token is
# an option value. Values count the tokens each option takes.
#
# config also owns --init and --verbose. They are absent because a
# forwarding component either owns them itself or must not pass them on.

typeset -gA SF_CREATE_OPTIONS=(
  --session-from 1 --config 1 -p 1 --profile 1 -m 1 --model 1 -b 1 --backend 1
  --request 1 --system 1 --system-file 1 --sandbox-read 1 --sandbox-write 1
  --sandbox-auto 0
)
