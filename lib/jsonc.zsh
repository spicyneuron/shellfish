emulate -R zsh
setopt no_aliases no_multios pipe_fail

# JSON with comments, as accepted for config files and component manifests.

# Comments are dropped but every line is preserved, so a jq parse error still
# reports the line and column the author wrote.
sf_jsonc_read() {
  awk '
    BEGIN { block = 0; string = 0; escaped = 0 }
    {
      for (i = 1; i <= length($0); i += 1) {
        character = substr($0, i, 1)
        next_character = substr($0, i + 1, 1)
        if (block) {
          if (character == "*" && next_character == "/") { block = 0; i += 1 }
          continue
        }
        if (string) {
          printf "%s", character
          if (escaped) escaped = 0
          else if (character == "\\") escaped = 1
          else if (character == "\"") string = 0
          continue
        }
        if (character == "\"") { string = 1; printf "%s", character }
        else if (character == "/" && next_character == "/") break
        else if (character == "/" && next_character == "*") { block = 1; i += 1; printf " " }
        else printf "%s", character
      }
      printf "\n"
    }
    END {
      if (block) { print "unterminated block comment" > "/dev/stderr"; exit 1 }
      if (string) { print "unterminated string" > "/dev/stderr"; exit 1 }
    }
  ' "$1" | jq -c .
}
