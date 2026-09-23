emulate -R zsh
setopt no_aliases no_multios pipe_fail

# JSON with comments, as accepted for profiles and component manifests.

# Comments are dropped but every line is preserved, so a jq parse error still
# reports the line and column the author wrote. With keyed=1 the files are
# collected into one object keyed by path, which costs the same two processes
# for any number of files.
typeset -g SF_JSONC_AWK='
  BEGIN { block = 0; string = 0; escaped = 0; if (keyed) printf "{" }
  keyed && FNR == 1 {
    name = FILENAME
    gsub(/["\\]/, "\\\\&", name)
    printf "%s\"%s\":", (started ? "," : ""), name
    started = 1
  }
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
    if (keyed) printf "}"
    if (block) { print "unterminated block comment" > "/dev/stderr"; exit 1 }
    if (string) { print "unterminated string" > "/dev/stderr"; exit 1 }
  }
'

sf_jsonc_read() {
  awk "$SF_JSONC_AWK" "$1" | jq -c .
}

# Later files shadow earlier ones under the same name.
sf_jsonc_read_keyed() {
  awk -v keyed=1 "$SF_JSONC_AWK" "$@" | jq -c .
}
