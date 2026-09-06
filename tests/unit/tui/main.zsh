#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

typeset entry="$ROOT/bin/shellfish" error
integer exit_code=0

# A non-PTY launch reaches terminal validation only after parsing its prompt.
exit_code=0
error=$(zsh -f "$entry" positional 2>&1) || exit_code=$?
[[ $error == *'chat requires an interactive terminal'* && $exit_code == 2 ]] || \
  fail 'implicit chat rejected its leading positional prompt'

exit_code=0
error=$(zsh -f "$entry" --profile default positional 2>&1) || exit_code=$?
[[ $error == *'chat requires an interactive terminal'* && $exit_code == 2 ]] || \
  fail 'implicit chat rejected its positional prompt after options'

exit_code=0
error=$(zsh -f "$entry" --session-from source.jsonl --system replacement 2>&1) || exit_code=$?
[[ $error == *'chat requires an interactive terminal'* && $exit_code == 2 ]] || \
  fail 'chat rejected a system replacement with --session-from'

exit_code=0
error=$(zsh -f "$entry" --session-from source.jsonl --draft draft positional 2>&1) || exit_code=$?
[[ $error == *'--draft cannot be combined with a prompt'* && $exit_code == 2 ]] || \
  fail 'chat consumed the prompt after --session-from'

exit_code=0
error=$(zsh -f "$entry" --session target.jsonl -s target.jsonl 2>&1) || exit_code=$?
[[ $error == *'--session may only be specified once'* && $exit_code == 2 ]] || \
  fail 'chat did not recognize -s as a repeated session'

exit_code=0
error=$(zsh -f "$entry" --draft 'editable prompt' 2>&1) || exit_code=$?
[[ $error == *'chat requires an interactive terminal'* && $exit_code == 2 ]] || \
  fail 'chat rejected a draft'

exit_code=0
error=$(zsh -f "$entry" --draft '' 2>&1) || exit_code=$?
[[ $error == *'chat requires an interactive terminal'* && $exit_code == 2 ]] || \
  fail 'chat rejected an empty draft'

exit_code=0
error=$(zsh -f "$entry" --draft draft positional 2>&1) || exit_code=$?
[[ $error == *'--draft cannot be combined with a prompt'* && $exit_code == 2 ]] || \
  fail 'chat accepted a draft with a positional prompt'

exit_code=0
error=$(print -rn piped | zsh -f "$entry" positional 2>&1) || exit_code=$?
[[ $error == *'cannot use a message argument and standard input together'* && \
  $exit_code == 2 ]] || \
  fail 'chat did not reject standard input with a positional prompt'
