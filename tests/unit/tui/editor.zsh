#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh

# Avoid the PTY worker.
sf_tui_heartbeat_arm() { return 0; }

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY='' ZLE_CALL=''
typeset -g SF_TUI_SESSION=session.jsonl
typeset -g SF_TUI_STATE=idle
typeset -g SF_TUI_FOOTER=test/model
typeset -gi COLUMNS=80 LINES=10
typeset -ga ZLE_CALLS=()
zle() {
  ZLE_CALL="$*"
  ZLE_CALLS+=( "$*" )
}
# Record submissions at the transport boundary.
typeset sent=''
sf_tui_transport_start() { sent=$(jq -r '.content[0].text' <<<"$1"); }

# Submit prompts without ending the editor.
BUFFER=prompt
SF_TUI_ACTION=''
ZLE_CALL=''
sf_tui_accept
assert_equal working "$SF_TUI_STATE"
assert_equal prompt "$sent"
assert_equal -R "$ZLE_CALL"

# Clear drafts on interrupt.
SF_TUI_STATE=idle
BUFFER=draft
sf_tui_interrupt
assert_equal '' "$BUFFER"
assert_equal 0 "$CURSOR"
assert_equal -R "$ZLE_CALL"

# Quit after a second interrupt.
sf_tui_interrupt
assert_equal quit "$SF_TUI_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal 130 "$SF_TUI_EXIT_STATUS"

# Escape may prefix a longer key sequence.
SF_TUI_STATE=working
SF_TUI_ACTION=''
ZLE_CALL=''
sf_tui_escape
assert_equal working "$SF_TUI_STATE"
assert_equal '' "$SF_TUI_ACTION"
assert_equal -R "$ZLE_CALL"

# Keep queued turns on interrupt.
SF_TUI_STATE=queued
SF_TUI_ACTION=''
ZLE_CALLS=()
sf_tui_interrupt
assert_equal queued "$SF_TUI_STATE"
assert_equal '' "$SF_TUI_ACTION"
assert_equal -R "$ZLE_CALLS[-1]"

# Quit while cancelling.
SF_TUI_STATE=cancelling
SF_TUI_ACTION=''
BUFFER=draft
ZLE_CALLS=()
sf_tui_interrupt
assert_equal draft "$BUFFER"
assert_equal quit "$SF_TUI_ACTION"
assert_equal 130 "$SF_TUI_EXIT_STATUS"
assert_equal accept-line "$ZLE_CALLS[-1]"

# Map permission keys and their numbers.
typeset -a permission_decisions=()
integer permission_holds=0
sf_tui_transport_reply() { [[ $2 == hold ]] && (( ++permission_holds )); }
sf_tui_answer_permission() { permission_decisions+=( "$1" ); SF_TUI_STATE=working; }
for KEYS in a d x 1 2; do
  SF_TUI_STATE=permission
  WIDGET=self-insert
  sf_tui_input
done
assert_equal 'approve,deny,approve,deny' "${(j:,:)permission_decisions}"
assert_equal 1 "$permission_holds"
assert_equal -R "$ZLE_CALL"

# Stop cancels the turn and restores the draft.
for KEYS in s 3; do
  SF_TUI_STATE=permission
  SF_TUI_PERMISSION_DRAFT=draft
  SF_TUI_PERMISSION_CURSOR=3
  BUFFER=''
  WIDGET=self-insert
  sf_tui_input
  assert_equal cancelling "$SF_TUI_STATE"
  assert_equal draft "$BUFFER"
done

# Accept client commands.
SF_TUI_ACTION=''
SF_TUI_STATE=idle
BUFFER=/quit
sf_tui_accept
assert_equal quit "$SF_TUI_ACTION"

# Insert literal newlines.
LBUFFER=first
sf_tui_insert_newline
assert_equal $'first\n' "$LBUFFER"

# Manage queued prompts.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_STATE=working
SF_TUI_QUEUE=()
SF_TUI_HISTORY=()
COLUMNS=43
LINES=15
BUFFER=$'first queued\ncontinued'
CURSOR=${#BUFFER}
sf_tui_accept
assert_equal '' "$BUFFER"
assert_equal 1 "${#SF_TUI_QUEUE}"
assert_equal $'first queued\ncontinued' "$SF_TUI_QUEUE[1]"

BUFFER='/queue'
CURSOR=${#BUFFER}
sf_tui_accept
assert_equal '' "$BUFFER"
assert_equal 1 "${#SF_TUI_QUEUE}"
assert_equal 1 "${#SF_TUI_HISTORY}"
[[ $ZLE_CALL == '-M '*'/queue drop N'*'/queue clear'*'Ctrl-X'* ]] ||
  fail 'bare queue command did not show queue help'

BUFFER='second queued'
CURSOR=${#BUFFER}
sf_tui_accept
BUFFER='/queue drop 1'
CURSOR=${#BUFFER}
sf_tui_accept
assert_equal 'second queued' "$SF_TUI_QUEUE[1]"
BUFFER='/queue clear'
CURSOR=${#BUFFER}
sf_tui_accept
assert_equal 0 "${#SF_TUI_QUEUE}"

# Send now resumes the oldest pending prompt without recording it twice.
SF_TUI_STATE=idle
SF_TUI_ACTION=''
SF_TUI_QUEUE=( first second )
SF_TUI_HISTORY=( first second )
BUFFER=''
ZLE_CALL=''
sf_tui_send
assert_equal working "$SF_TUI_STATE"
assert_equal first "$sent"
assert_equal second "${(j:,:)SF_TUI_QUEUE}"
assert_equal first,second "${(j:,:)SF_TUI_HISTORY}"
assert_equal -R "$ZLE_CALL"

# A draft takes priority over the paused queue.
SF_TUI_STATE=idle
SF_TUI_ACTION=''
BUFFER=now
sf_tui_send
assert_equal working "$SF_TUI_STATE"
assert_equal now "$sent"
assert_equal second "${(j:,:)SF_TUI_QUEUE}"
assert_equal '' "$BUFFER"

# Queued client commands still dispatch through their normal boundary.
SF_TUI_STATE=idle
SF_TUI_ACTION=''
SF_TUI_QUEUE=( /quit )
sf_tui_send
assert_equal quit "$SF_TUI_ACTION"
assert_equal 0 "${#SF_TUI_QUEUE}"
assert_equal accept-line "$ZLE_CALL"

# Navigate history and multiline display rows.
SF_TUI_HISTORY=()
sf_tui_record_prompt first
sf_tui_record_prompt second
BUFFER=draft
CURSOR=3
sf_tui_up
assert_equal second "$BUFFER"
sf_tui_up
assert_equal first "$BUFFER"
sf_tui_down
sf_tui_down
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
BUFFER=${(l:70::x:)''}
CURSOR=70
COLUMNS=50
sf_tui_up
assert_equal 20 "$CURSOR"

# Permission state gates editing even when ZLE decoded the key beforehand.
SF_TUI_STATE=permission
BUFFER=''
ZLE_CALLS=()
for WIDGET in sf_tui_up sf_tui_down sf_tui_accept sf_tui_insert_newline \
    kill-word yank history-incremental-search-backward send-break; do
  sf_tui_input
done
assert_equal '' "$BUFFER"
assert_equal 0 "${#ZLE_CALLS}"
WIDGET=bracketed-paste
sf_tui_input
assert_equal '.bracketed-paste paste' "$ZLE_CALL"

# Idle and working states share normal editing.
WIDGET=self-insert
for SF_TUI_STATE in idle working; do
  sf_tui_input
  assert_equal '.self-insert --' "$ZLE_CALL"
done

# Wrapped kills keep appending to the cutbuffer.
SF_TUI_STATE=idle
ZLE_CALLS=()
WIDGET=backward-kill-word
sf_tui_input
assert_equal '-f kill,.backward-kill-word --' "${(j:,:)ZLE_CALLS}"

# Range completion preserves surrounding text and places the cursor after insertion.
BUFFER=$'前文\nUse $co later'
CURSOR=10
sf_tui_complete_range 7 10 '$code-review'
assert_equal $'前文\nUse $code-review later' "$BUFFER"
assert_equal 19 "$CURSOR"
assert_equal 0 "${#SF_TUI_COMPLETIONS}"

# Shared prefixes extend the typed text, a single match replaces it, and other
# matches leave it for the list.
BUFFER='Read @sr then'
CURSOR=8
sf_tui_complete_range 5 8 @src/editor.zsh @src/controller.zsh
assert_equal 'Read @src/ then' "$BUFFER"
assert_equal 10 "$CURSOR"
assert_equal '@src/editor.zsh,@src/controller.zsh' "${(j:,:)SF_TUI_COMPLETIONS}"
BUFFER='Read @edi then'
CURSOR=9
sf_tui_complete_range 5 9 @src/editor.zsh @tests/editor.zsh
assert_equal 'Read @edi then' "$BUFFER"
assert_equal 9 "$CURSOR"
assert_equal '@src/editor.zsh,@tests/editor.zsh' "${(j:,:)SF_TUI_COMPLETIONS}"
sf_tui_complete_range 5 9 @src/editor.zsh
assert_equal 'Read @src/editor.zsh then' "$BUFFER"
assert_equal 20 "$CURSOR"
assert_equal 0 "${#SF_TUI_COMPLETIONS}"
sf_tui_complete_range 5 20
assert_equal 'Read @src/editor.zsh then' "$BUFFER"
assert_equal 20 "$CURSOR"
assert_equal 0 "${#SF_TUI_COMPLETIONS}"

# Empty ranges support insertion, including at either buffer edge.
BUFFER='tail'
CURSOR=0
sf_tui_complete_range 0 0 'prefix '
assert_equal 'prefix tail' "$BUFFER"
assert_equal 7 "$CURSOR"
CURSOR=${#BUFFER}
sf_tui_complete_range $CURSOR $CURSOR ' end'
assert_equal 'prefix tail end' "$BUFFER"
assert_equal 15 "$CURSOR"

# Any input dismisses completion candidates before handling the key.
for WIDGET in self-insert backward-char sf_tui_escape sf_tui_accept; do
  SF_TUI_COMPLETIONS=( /queue /quit )
  BUFFER=''
  sf_tui_input
  assert_equal 0 "${#SF_TUI_COMPLETIONS}"
done
SF_TUI_COMPLETIONS=( /queue /quit )
sf_tui_editor_permission open
assert_equal 0 "${#SF_TUI_COMPLETIONS}"
sf_tui_editor_permission restore

# Tab cycles an open list and shift+tab reverses, wrapping and keeping later text.
SF_TUI_COMMANDS=( /queue /quit /refresh )
BUFFER='/q tail'
CURSOR=2
for WIDGET match number in sf_tui_complete /qu 0 sf_tui_complete /queue 1 \
    sf_tui_complete /quit 2 sf_tui_complete /queue 1 sf_tui_complete_back /quit 2; do
  sf_tui_input
  assert_equal "$match tail" "$BUFFER"
  assert_equal ${#match} "$CURSOR"
  assert_equal $number "$SF_TUI_COMPLETION_NO"
  assert_equal '/queue,/quit' "${(j:,:)SF_TUI_COMPLETIONS}"
done
WIDGET=self-insert
sf_tui_input
assert_equal '/quit tail' "$BUFFER"
assert_equal 0 "${#SF_TUI_COMPLETIONS}"

# Shift+tab starts at the last match, and does nothing without a list.
BUFFER='/q'
CURSOR=2
WIDGET=sf_tui_complete_back
sf_tui_input
assert_equal '/q' "$BUFFER"
WIDGET=sf_tui_complete
sf_tui_input
WIDGET=sf_tui_complete_back
sf_tui_input
assert_equal '/quit' "$BUFFER"
assert_equal 2 "$SF_TUI_COMPLETION_NO"
SF_TUI_COMPLETIONS=()

# Complete only the leading command and preserve the rest of the draft.
SF_TUI_COMMANDS=( /fork /help /queue /quit /refresh )
WIDGET=sf_tui_complete
for before cursor after final_cursor in \
    /h 2 /help 5 /help 5 /help 5 /qui 4 /quit 5 /ref 4 /refresh 8 /for 4 /fork 5 \
    /missing 8 /missing 8 ordinary 8 ordinary 8 \
    '/for arg' 8 '/for arg' 8 '/hel arg' 4 '/help arg' 5 /hel 3 /hel 3 \
    $'/hel\n/for' 9 $'/hel\n/for' 9 $'/hel\ntail' 4 $'/help\ntail' 5; do
  BUFFER=$before CURSOR=$cursor
  sf_tui_input
  assert_equal "$after" "$BUFFER"
  assert_equal "$final_cursor" "$CURSOR"
done

# An @path completes one folder at a time under the session's directory, marking
# folders and showing hidden files only after a typed dot. A bare name also
# matches deeper file names that Git does not ignore.
sf_test_tmp editor
mkdir -p "$tmp/project/"{lib,libexec/tui,build} "$tmp/plain/sub"
touch "$tmp/project/"{README.md,.hidden} "$tmp/project/lib/"{cli.zsh,session.zsh} \
  "$tmp/project/libexec/tui/"{controller.zsh,editor.zsh} "$tmp/project/build/ignored.txt" \
  "$tmp/plain/sub/editor.zsh"
print -r -- 'build/' >"$tmp/project/.gitignore"
git -C "$tmp/project" init -q
SF_TUI_CWD=$tmp/project
WIDGET=sf_tui_complete
for before after matches in \
  'Read @li' 'Read @lib' '@lib/,@libexec/' \
  'Read @lib/' 'Read @lib/' '@lib/cli.zsh,@lib/session.zsh' \
  'Read @lib/c' 'Read @lib/cli.zsh' '' \
  '@R' '@README.md' '' \
  '@' '@' '@README.md,@build/,@lib/,@libexec/' \
  '@.h' '@.hidden' '' \
  '@edi' '@libexec/tui/editor.zsh' '' \
  '@c' '@c' '@lib/cli.zsh,@libexec/tui/controller.zsh' \
  '@ign' '@ign' '' \
  '@missing' '@missing' '' \
  'a@li' 'a@li' '' \
  'say /qu' 'say /qu' ''; do
  BUFFER="$before then"
  CURSOR=${#before}
  SF_TUI_COMPLETIONS=()
  sf_tui_input
  assert_equal "$after then" "$BUFFER"
  assert_equal ${#after} "$CURSOR"
  assert_equal "$matches" "${(j:,:)${(@o)SF_TUI_COMPLETIONS}}"
done

# Outside Git, only the current folder level matches.
SF_TUI_CWD=$tmp/plain
BUFFER='@edi'
CURSOR=4
sf_tui_input
assert_equal '@edi' "$BUFFER"
assert_equal 0 "${#SF_TUI_COMPLETIONS}"
SF_TUI_CWD=$tmp/project

# Completion needs the cursor at the end of a word.
BUFFER='@li then'
CURSOR=2
sf_tui_input
assert_equal '@li then' "$BUFFER"
SF_TUI_COMPLETIONS=()

# Bind documented editor keys.
bindkey -e
ZLE_CALLS=()
sf_tui_bind
[[ $(bindkey -M sf-present '^M') == *sf_tui_accept ]]
[[ $(bindkey -M sf-present '^I') == *sf_tui_complete ]]
[[ $(bindkey -M sf-present $'\e[Z') == *sf_tui_complete_back ]]
[[ $(bindkey -M sf-present $'\e[13;2u') == *sf_tui_insert_newline ]]
[[ $(bindkey -M sf-present $'\e[A') == *sf_tui_up ]]
[[ $(bindkey -M sf-present $'\e[B') == *sf_tui_down ]]
[[ $(bindkey -M sf-present '^C') == *sf_tui_interrupt ]]
[[ $(bindkey -M sf-present '^X') == *sf_tui_send ]]
[[ $(bindkey -M sf-present $'\e[13;5u') == *sf_tui_send ]]
[[ $(bindkey -M sf-present $'\e[13;9u') == *sf_tui_send ]]
[[ $(bindkey -M sf-present $'\e') == *sf_tui_escape ]]
[[ $(bindkey -M sf-present x) == *self-insert ]]
[[ $(bindkey -M sf-present $'\xe9') == *self-insert ]]
[[ $(bindkey -M sf-present '^D') == *' delete-char' ]]
[[ $(bindkey -M sf-present $'\e[3~') == *' delete-char' ]]
[[ $(bindkey -M sf-present $'\e[H') == *beginning-of-line ]]
[[ $(bindkey -M sf-present $'\e[F') == *end-of-line ]]
[[ $(bindkey -M sf-present $'\e[1;5D') == *backward-word ]]
[[ $(bindkey -M sf-present $'\e[1;3C') == *forward-word ]]

# Inherit no editor commands beyond the explicit bindings.
for key in '^[x' '^[z' '^R' '^_' '^O'; do
  [[ $(bindkey -M sf-present $key) == *undefined-key ]] ||
    fail "$key is bound"
done
for binding in "${(@f)$(bindkey -M sf-present)}"; do
  widget=${binding##* }
  (( ${ZLE_CALLS[(Ie)-N $widget sf_tui_input]} )) ||
    fail "$widget bypassed input dispatch"
done

# Leave the editor if the turn cannot start.
typeset saved_start=$functions[sf_tui_transport_start]
sf_tui_transport_start() { SF_TUI_TRANSPORT_ERROR='cannot start test turn'; return 1; }
SF_TUI_STATE=idle
SF_TUI_ERROR=''
SF_TUI_ACTION=''
BUFFER=unstartable
sf_tui_accept || fail 'accept reported a failure'
assert_equal failed "$SF_TUI_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal 'cannot start test turn' "$SF_TUI_ERROR"
functions[sf_tui_transport_start]=$saved_start

# Clipboard readers and a failing optional resizer are isolated from host tools.
sf_test_tmp tui-editor-paste
mkdir -p "$tmp/bin" "$tmp/paste"
for command in head od tr grep mktemp rm; do
  ln -s "$commands[$command]" "$tmp/bin/$command"
done
print -r -- '#!/bin/sh
case "$*:$FAKE_CLIPBOARD" in
  *TARGETS*|*--list-types*)
    case "$FAKE_CLIPBOARD" in
      png|failed) printf "text/plain\nimage/png\n" ;;
      mixed) printf "image/bmp\nimage/png\n" ;;
      bmp) printf "image/bmp\n" ;;
      text) printf "text/plain\n" ;;
    esac ;;
  *image/png*) printf "\211PNG\r\n\032\n" ;;
  *image/bmp*) printf "BM bitmap" ;;
esac
[ "$FAKE_CLIPBOARD" != failed ]' >"$tmp/bin/xclip"
print -r -- '#!/bin/sh
exit 1' >"$tmp/bin/magick"
chmod +x "$tmp/bin/xclip" "$tmp/bin/magick"
for reader in xclip wl-paste; do
  [[ $reader != wl-paste ]] || ln -s xclip "$tmp/bin/wl-paste"
  (
    path=( "$tmp/bin" )
    for clipboard in png mixed bmp text failed; do
      LBUFFER='look '
      FAKE_CLIPBOARD=$clipboard TMPDIR=$tmp/paste sf_tui_paste_image
      if [[ $clipboard == (png|mixed) ]]; then
        [[ $LBUFFER == "look [Image: $tmp/paste/shellfish-paste."* ]] ||
          fail "a $clipboard clipboard inserted $LBUFFER through $reader"
        sf_tui_image_format "${${LBUFFER#*\[Image: }%\]}" && [[ $REPLY == png ]] ||
          fail 'the pasted image was not saved'
        sf_tui_paste_cleanup
        left=( $tmp/paste/*(N) )
        assert_equal 0 ${#left} "cleanup left a $clipboard paste from $reader"
      else
        assert_equal 'look ' "$LBUFFER" "a $clipboard clipboard inserted a marker through $reader"
        left=( $tmp/paste/*(N) )
        assert_equal 0 ${#left} "a $clipboard clipboard left a file"
      fi
    done
  )
done
