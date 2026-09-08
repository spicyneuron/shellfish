#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp install-session

typeset entry="$ROOT/bin/shellfish"
typeset header="$SF_TEST_SESSIONS/header-only.jsonl"
typeset output="$tmp/output.jsonl" installed

# Installation preserves a complete transcript byte for byte and reports its
# absolute destination.
installed=$(zsh -f "$entry" install-session --session-out "$output" <"$header") ||
  fail 'canonical installation failed'
assert_equal "$output" "$installed"
cmp -s "$header" "$output" || fail 'installation changed transcript bytes'
[[ $(stat -f '%Lp' "$output") == 600 ]] || fail 'installed session mode is not 0600'

# Visible and feature-owned leading-dot names are both ordinary destinations.
for name in visible.jsonl .agent-a1b2c3.jsonl; do
  zsh -f "$entry" install-session --session-out "$tmp/$name" <"$header" >/dev/null ||
    fail "installation rejected $name"
done

# A recoverable tail is publishable. Ordinary recovery closes the turn later.
typeset unanswered="$tmp/unanswered-input.jsonl"
cat "$header" >"$unanswered"
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"waiting"}]}' \
  >>"$unanswered"
zsh -f "$entry" install-session --session-out "$tmp/unanswered.jsonl" <"$unanswered" \
  >/dev/null || fail 'installation rejected an unanswered user message'
cmp -s "$unanswered" "$tmp/unanswered.jsonl" || fail 'recoverable transcript was rewritten'

# State is inert, while conversation sequencing remains required.
typeset complete="$tmp/complete-input.jsonl" complete_output="$tmp/complete.jsonl"
cat "$header" >"$complete"
cat >>"$complete" <<'EOF'
{"type":"state","name":"agents/a1b2c3","value":{"session":".agent-a1b2c3.jsonl"}}
{"type":"message","role":"user","content":[{"type":"text","text":"hello"}]}
{"type":"message","role":"assistant","stop":"end","content":[]}
{"type":"state","name":"agents/a1b2c3","value":null}
EOF
zsh -f "$entry" install-session --session-out "$complete_output" <"$complete" >/dev/null ||
  fail 'installation rejected complete state-bearing transcript'
cmp -s "$complete" "$complete_output" || fail 'complete transcript was rewritten'

# Existing files, directories, and symlinks are never replaced or removed.
typeset occupied="$tmp/occupied.jsonl" empty="$tmp/empty.jsonl" directory="$tmp/directory.jsonl"
typeset symlink="$tmp/symlink.jsonl" dangling="$tmp/dangling.jsonl"
print -r -- sentinel >"$occupied"
: >"$empty"
mkdir "$directory"
ln -s "$occupied" "$symlink"
ln -s "$tmp/missing.jsonl" "$dangling"
for target in "$occupied" "$empty" "$directory" "$symlink" "$dangling"; do
  zsh -f "$entry" install-session --session-out "$target" <"$header" \
    >/dev/null 2>&1 && fail "installation replaced occupied destination: $target"
done
assert_equal sentinel "$(<"$occupied")"
[[ -f $empty && ! -s $empty && -d $directory && -L $symlink && -L $dangling ]] ||
  fail 'collision cleanup changed an occupied destination'

# Invalid framing, schema versions, records, and sequencing publish nothing.
typeset invalid="$tmp/invalid-input.jsonl" target="$tmp/rejected.jsonl"
typeset -a cases=( empty malformed missing-newline blank-line unsupported invalid-record unmatched-result )
typeset -a leftovers
for case_name in $cases; do
  case $case_name in
    empty) : >"$invalid" ;;
    malformed) print -r -- '{"type":"session"' >"$invalid" ;;
    missing-newline) print -rn -- "$(<"$header")" >"$invalid" ;;
    blank-line) cat "$header" >"$invalid"; print >>"$invalid" ;;
    unsupported) sed '1s/"format_version":1/"format_version":2/' "$header" >"$invalid" ;;
    invalid-record)
      cat "$header" >"$invalid"
      print -r -- '{"type":"state","name":"bad name","value":true}' >>"$invalid"
      ;;
    unmatched-result)
      cat "$header" >"$invalid"
      print -r -- \
        '{"type":"message","role":"tool_result","call_id":"call_1","name":"shell","content":"out","exit_code":0}' \
        >>"$invalid"
      ;;
  esac
  zsh -f "$entry" install-session --session-out "$target" <"$invalid" \
    >/dev/null 2>&1 && fail "installation accepted $case_name input"
  [[ ! -e $target && ! -L $target ]] || fail "$case_name input left a destination"
  leftovers=( "$tmp"/.rejected.jsonl.*(N) )
  (( ! ${#leftovers} )) || fail "$case_name input left a temporary file"
done

# A destination created after validation begins wins the publication race.
typeset fifo="$tmp/input.fifo" raced="$tmp/raced.jsonl" race_error="$tmp/race-error"
typeset release="$tmp/release"
mkfifo "$fifo"
{ while [[ ! -e $release ]]; do sleep 0.02; done; cat "$header" } >"$fifo" &
integer writer_pid=$!
zsh -f "$entry" install-session --session-out "$raced" <"$fifo" \
  >/dev/null 2>"$race_error" &
integer install_pid=$! waited=0 install_status=0
while (( waited++ < 50 )); do
  leftovers=( "$tmp"/.raced.jsonl.*(N) )
  (( ${#leftovers} )) && break
  sleep 0.02
done
(( waited <= 50 )) || fail 'installer did not prepare its temporary file'
print -r -- sentinel >"$raced"
: >"$release"
wait $writer_pid
wait $install_pid || install_status=$?
(( install_status != 0 )) || fail 'installer overwrote a racing destination'
assert_equal sentinel "$(<"$raced")"
leftovers=( "$tmp"/.raced.jsonl.*(N) )
(( ! ${#leftovers} )) || fail 'collision left a temporary file'

# Argument validation happens without consuming or publishing input.
zsh -f "$entry" install-session <"$header" >/dev/null 2>&1 &&
  fail 'installer accepted a missing destination option'
zsh -f "$entry" install-session --session-out '' <"$header" >/dev/null 2>&1 &&
  fail 'installer accepted an empty destination'
zsh -f "$entry" install-session --session-out "$tmp/a" --session-out "$tmp/b" \
  <"$header" >/dev/null 2>&1 && fail 'installer accepted repeated destinations'
zsh -f "$entry" install-session --session-out "$tmp/extra" argument \
  <"$header" >/dev/null 2>&1 && fail 'installer accepted an extra argument'

print -r -- ok
