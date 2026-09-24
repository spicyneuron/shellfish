emulate -R zsh
setopt no_aliases no_multios pipe_fail

# JSON with comments and trailing commas, as accepted for profiles and manifests.

# Comments are dropped and trailing commas become spaces, preserving lines for
# jq diagnostics. With keyed=1, files become an object keyed by path.
typeset -g SF_JSONC_AWK='
  function flush_comma() {
    if (comma) { printf ",%s", gap; comma = 0; gap = "" }
  }
  function emit(ch) {
    if (comma) {
      if (ch ~ /^[[:space:]]$/) { gap = gap ch; return }
      printf "%s%s", ((ch == "]" || ch == "}") ? " " : ","), gap
      comma = 0; gap = ""
    }
    if (ch == "," && last_sig != "[" && last_sig != "{") comma = 1
    else printf "%s", ch
    if (ch !~ /^[[:space:]]$/) last_sig = ch
  }
  BEGIN { block = 0; string = 0; escaped = 0; if (keyed) printf "{" }
  keyed && FNR == 1 {
    flush_comma()
    last_sig = ""
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
      if (character == "\"") { string = 1; emit(character) }
      else if (character == "/" && next_character == "/") break
      else if (character == "/" && next_character == "*") { block = 1; i += 1; emit(" ") }
      else emit(character)
    }
    emit("\n")
  }
  END {
    flush_comma()
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
