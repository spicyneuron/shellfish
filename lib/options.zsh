# Arity of options that clients may forward to session creation.
# --verbose remains owned by its parsing client.
typeset -gA SF_CREATE_OPTIONS=(
  --session-from 1 -p 1 --profile 1 -m 1 --model 1 --sandbox 1 --system 1
  -t 1 --tool 1 --command 1 --hook 1 --sandbox-auto 0
)
