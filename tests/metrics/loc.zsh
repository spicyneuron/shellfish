#!/usr/bin/env zsh

emulate -R zsh
setopt err_exit no_aliases no_multios pipe_fail

if (( ! $+commands[tokei] )); then
  print -u2 -r -- 'Install tokei to report source lines: https://github.com/XAMPPRocky/tokei'
  exit 2
fi

typeset -r root=${0:A:h:h:h}
typeset -a core terminal server sources

core=( "$root/bin/shellfish" "$root"/lib/**/*.(zsh|jq)(N.) )
core=( ${core:#$root/lib/chat/*} )
terminal=( "$root"/lib/chat/**/*.(zsh|jq|awk)(N.) )
server=( "$root"/server/**/*.(go|js|css|html)(N.) )
server=( ${server:#*_test.(go|js)} )

sources=( $core $terminal $server )
print -P -- '%BSource Lines%b'
tokei --compact --streaming simple -- $sources | awk -v root="$root" '
  BEGIN {
    labels[1] = "Core"
    labels[2] = "Terminal client"
    labels[3] = "Web server and client"
  }

  /^# language/ {
    for (field = 3; field <= NF; field++) offset[$field] = NF - field
    next
  }

  /^#/ { next }

  {
    records++
    path = $2
    for (field = 3; field <= NF - 4; field++) path = path " " $field

    if (index(path, root "/server/") == 1) {
      group = 3
    } else if (index(path, root "/lib/chat/") == 1) {
      group = 2
    } else {
      group = 1
    }

    files[group]++
    lines[group] += $(NF - offset["lines"])
    code[group] += $(NF - offset["code"])
    comments[group] += $(NF - offset["comments"])
    blanks[group] += $(NF - offset["blanks"])
  }

  END {
    if (!records) exit
    printf "%-24s %7s %9s %9s %10s %9s\n", "Group", "Files", "Lines", "Code", "Comments", "Blanks"
    printf "%-24s %7s %9s %9s %10s %9s\n", "------------------------", "-------", "---------", "---------", "----------", "---------"
    for (group = 1; group <= 3; group++) {
      printf "%-24s %7d %9d %9d %10d %9d\n", labels[group], files[group], lines[group], code[group], comments[group], blanks[group]
      total_files += files[group]
      total_lines += lines[group]
      total_code += code[group]
      total_comments += comments[group]
      total_blanks += blanks[group]
    }
    printf "%-24s %7s %9s %9s %10s %9s\n", "------------------------", "-------", "---------", "---------", "----------", "---------"
    printf "%-24s %7d %9d %9d %10d %9d\n", "Total", total_files, total_lines, total_code, total_comments, total_blanks
  }
'
