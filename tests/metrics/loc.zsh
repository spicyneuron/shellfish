#!/usr/bin/env zsh

if (( ! $+commands[tokei] )); then
  print -u2 -r -- 'Install tokei to report source lines: https://github.com/XAMPPRocky/tokei'
  exit 2
fi

typeset -r root=${0:A:h:h:h}
typeset -a core terminal server server_tests terminal_tests

core=( "$root/bin/shellfish" "$root"/lib/**/*.(zsh|jq)(N.) )
core=( ${core:#$root/lib/chat/*} )
terminal=( "$root"/lib/chat/**/*.(zsh|jq|awk)(N.) )
terminal_tests=( "$root"/tests/**/*.(zsh|py)(N.) )
server=( "$root"/server/**/*.(go|js|css|html)(N.) )
server=( ${server:#*_test.(go|js)} )
server_tests=( "$root"/server/**/*_test.(go|js)(N.) )

print -r -- 'Core'
tokei --compact -- $core
print
print -r -- 'Terminal client'
tokei --compact -- $terminal
print
print -r -- 'Terminal tests'
tokei --compact -- $terminal_tests
print
print -r -- 'Web server and client'
tokei --compact -- $server
print
print -r -- 'Web tests'
tokei --compact -- $server_tests
