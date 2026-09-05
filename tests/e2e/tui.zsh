#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"

typeset entry="$ROOT/bin/shellfish" error output
integer exit_code=0

# Help and version are first-token routes; remaining arguments are not parsed.
output=$(zsh -f "$entry" --help ignored)
[[ $output == 'Shellfish: '* && $output == *$'\nUsage:\n'* ]] || fail 'help route failed'
assert_equal "shellfish $(<"$ROOT/VERSION")" "$(zsh -f "$entry" --version ignored)"

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
error=$(zsh -f "$entry" run --draft draft prompt 2>&1) || exit_code=$?
[[ $error == *'unknown argument: --draft'* && $exit_code == 2 ]] || \
  fail 'run accepted a draft'

exit_code=0
error=$(print -rn piped | zsh -f "$entry" chat 2>&1) || exit_code=$?
[[ $error == *'cannot use a message argument and standard input together'* && \
  $exit_code == 2 ]] || \
  fail 'chat is still treated as a command instead of a prompt'

exit_code=0
error=$(print -rn piped | zsh -f "$entry" positional 2>&1) || exit_code=$?
[[ $error == *'cannot use a message argument and standard input together'* && \
  $exit_code == 2 ]] || \
  fail 'chat did not reject standard input with a positional prompt'

print -r -- ok
