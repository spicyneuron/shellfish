#!/usr/bin/env zsh

emulate -R zsh
setopt err_exit no_aliases no_multios pipe_fail

if (( ! $+commands[tokei] )); then
  print -u2 -r -- 'Install tokei to report source lines: https://github.com/XAMPPRocky/tokei'
  exit 2
fi

typeset -r root=${0:A:h:h:h}
typeset stage
stage=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-loc.XXXXXX") || exit
trap 'rm -rf -- $stage' EXIT

typeset -i staged=0
typeset -a totals=(0 0 0 0 0)
typeset -r head_format='%-24s %7s %9s %9s %10s %9s\n'
typeset -r row_format='%-24s %7d %9d %9d %10d %9d\n'
typeset divider
divider=$(printf $head_format ------------------------ ------- --------- --------- ---------- ---------)

# tokei picks the language from the file extension, so a file it would skip is
# counted through a staged copy carrying an extension it recognizes.
group() {
  local label=$1 file copy index
  local -a files=() counts=()
  shift

  for file in "$@"; do
    case $file in
      *.jsonc) copy=$stage/$((++staged)).js ;;
      *.*) files+=( $file ); continue ;;
      *) copy=$stage/$((++staged)).zsh ;;
    esac
    cp -- $file $copy
    files+=( $copy )
  done

  counts=( ${=$(tokei --compact --streaming simple -- $files | awk '
    /^# language/ {
      for (field = 3; field <= NF; field++) offset[$field] = NF - field
      next
    }

    /^#/ { next }

    {
      files++
      lines += $(NF - offset["lines"])
      code += $(NF - offset["code"])
      comments += $(NF - offset["comments"])
      blanks += $(NF - offset["blanks"])
    }

    END { printf "%d %d %d %d %d\n", files, lines, code, comments, blanks }
  ')} )

  printf $row_format $label $counts
  for index in {1..5}; do
    totals[index]=$(( totals[index] + counts[index] ))
  done
}

typeset -a core terminal harness server shell_tests server_tests

core=( "$root/bin/shellfish" "$root"/(lib|libexec)/**/*.(zsh|jq)(N.) )
core=( ${core:#$root/libexec/(tui|resume)/*} )
terminal=( "$root"/libexec/(tui|resume)/**/*.(zsh|jq|awk)(N.) )
harness=( "$root"/share/default/**/*(N.) )
server=( "$root"/shellfish-server/**/*.(go|js|css|html)(N.) )
server_tests=( ${(M)server:#*_test.(go|js)} )
server=( ${server:#*_test.(go|js)} )
# Every file under tests/ is test source, apart from fixture data.
shell_tests=( "$root"/tests/**/*(N.) )
shell_tests=( ${shell_tests:#*.(json|jsonl|pyc)} )

print -P -- '%BSource Lines%b'
printf $head_format Group Files Lines Code Comments Blanks
print -r -- $divider
group 'Core' $core
group 'Default harness' $harness
group 'Terminal client' $terminal
group 'Server and client' $server
print -r -- $divider
group 'Shell tests' $shell_tests
group 'Server tests' $server_tests
print -r -- $divider
printf $row_format Total $totals
