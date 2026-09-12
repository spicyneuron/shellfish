# Arity of options that clients may forward to session creation.
# --init and --verbose remain owned by their parsing clients.
typeset -gA SF_CREATE_OPTIONS=(
  --session-from 1 --config 1 -p 1 --profile 1 -m 1 --model 1 -b 1 --backend 1
  --request 1 --system 1 --system-file 1 --sandbox-read 1 --sandbox-write 1
  --sandbox-auto 0
)
