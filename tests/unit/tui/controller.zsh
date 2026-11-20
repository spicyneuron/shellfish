#!/usr/bin/env zsh

# Turn workflow: draining core output, permissions, queues, and recovery.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh libexec/tui/project.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh
sf_test_tmp controller
typeset SF_ENTRY="$ROOT/bin/shellfish"
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY='' ZLE_CALLS=''
typeset -gi COLUMNS=80 LINES=20
zle() { ZLE_CALLS+="${ZLE_CALLS:+,}$*" }

# Avoid the PTY worker.
sf_tui_heartbeat_arm() { return 0; }

pump() {
  SF_TUI_TRANSPORT_LINES=( "$@" )
  sf_tui_pending_next || fail 'draining core output failed'
}

# Completion keeps command names and longer aliases, not single-letter aliases.
mkdir -p "$tmp/commands/example"
print -r -- '#!/bin/sh' >"$tmp/commands/example/run"
chmod +x "$tmp/commands/example/run"
print -r -- '{"description":"Example command","aliases":["e","example-alias"]}' \
  >"$tmp/commands/example/manifest.json"
sf_tui_commands "$tmp/commands/example" @commands/help
assert_equal '/example,/example-alias,/help,/queue,/quit,/refresh,/verbose' \
  "${(j:,:)SF_TUI_COMMANDS}"
SF_TUI_COMPLETIONS=( /example /example-alias )
sf_tui_commands
assert_equal '/queue,/quit,/refresh,/verbose' "${(j:,:)SF_TUI_COMMANDS}"
assert_equal 0 "${#SF_TUI_COMPLETIONS}"

# Hook prefixes are cataloged independently and reset on a profile update.
sf_test_hook "$tmp/hooks/example" '{"on":"stop","complete":"%"}' <<<'#!/bin/sh'
sf_tui_apply hook_completions "$tmp/hooks/example" @hooks/skills/mention
assert_equal '$,%' "${(j:,:)SF_TUI_COMPLETION_PREFIXES}"
SF_TUI_COMPLETIONS=( '%example' )
sf_tui_apply hook_completions
assert_equal 0 "${#SF_TUI_COMPLETION_PREFIXES}"
assert_equal 0 "${#SF_TUI_COMPLETIONS}"

# File completion follows the header's stored working directory.
HOME=$tmp sf_tui_apply cwd '~/project'
assert_equal "${tmp:A}/project" "$SF_TUI_CWD"

# Client aliases share the catalog used by completion.
SF_TUI_SESSION=example.jsonl
for input in /quit /q; do
  SF_TUI_ACTION=''
  sf_tui_client_command "$input" || fail "client command failed: $input"
  assert_equal quit "$SF_TUI_ACTION"
done
for input in /refresh /r; do
  SF_TUI_ACTION=''
  sf_tui_client_command "$input" || fail "client command failed: $input"
  assert_equal handoff "$SF_TUI_ACTION"
  assert_equal "$SF_ENTRY --clear --session example.jsonl" "${(j: :)SF_TUI_HANDOFF}"
done
SF_TUI_ACTION=''
SF_TUI_HANDOFF=()
sf_tui_client_command '/q extra' && fail 'client alias accepted arguments'

# Replay complete session lines directly and reject invalid physical input.
typeset replay="$tmp/replay.jsonl" malformed="$tmp/malformed.jsonl" torn="$tmp/torn.jsonl"
cp "$SF_TEST_SESSIONS/complete.jsonl" "$replay"
SF_TUI_SESSION=$replay
SF_TUI_STATE=idle
SF_TUI_HISTORY=()
sf_tui_load "$replay" || fail 'direct session replay failed'
assert_equal test/fake-model "$SF_TUI_IDENTITY"
# Replayed prompts are recallable.
assert_equal Hello "${(j:,:)SF_TUI_HISTORY}"
print -r -- 'not json' >"$malformed"
sf_tui_load "$malformed" && fail 'malformed session replay succeeded'
assert_equal "cannot present session: $malformed" "$SF_TUI_ERROR"
print -n -r -- '{"type":"user"' >"$torn"
sf_tui_load "$torn" && fail 'incomplete session replay succeeded'
assert_equal "cannot read incomplete session: $torn" "$SF_TUI_ERROR"

# Resume activity is transient on both success and failure.
sf_tui_resume "$replay" >"$tmp/loading" || fail 'resume failed'
assert_equal test/fake-model "$SF_TUI_IDENTITY"
[[ $(<"$tmp/loading") == *'Loading session…'*$'\r\e[2K' ]] ||
  fail 'resume did not clear loading activity'
sf_tui_resume "$malformed" >"$tmp/loading" && fail 'invalid resume succeeded'
assert_equal "cannot present session: $malformed" "$SF_TUI_ERROR"
[[ $(<"$tmp/loading") == *$'\r\e[2K' ]] || fail 'failed resume left loading activity'
assert_equal '' "$(jobs -p)"

# Model context settles under its lifecycle without exposing model text.
SF_TUI_SESSION="$tmp/session.jsonl"
SF_TUI_STATE=working
sf_tui_reset
pump '{"type":"_draft","lifecycle":"session_start","id":"2","user_text":"Loading git environment…"}'
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT == *'Loading git environment'* ]] ||
  fail 'hook activity did not reach the viewport'
pump '{"type":"hook_result","lifecycle":"session_start","id":"2","model_text":"Git branch: secret"}'
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT != *'↪ session_start'* &&
    $SF_TUI_VIEWPORT_TEXT != *'Loading git environment'* &&
    $SF_TUI_VIEWPORT_TEXT != *'Git branch: secret'* ]] ||
  fail 'model-only hook result did not settle as private context'

# Present one turn.
SF_TUI_SESSION="$tmp/session.jsonl"
SF_TUI_STATE=working
sf_tui_reset
sf_tui_terminal_reset
pump '{"type":"_assistant_start"}' \
  '{"type":"_assistant_message_delta","text":"part "}' \
  '{"type":"_assistant_reasoning_delta","text":"thought"}' \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"part "},{"type":"reasoning","text":"thought"}],"usage":{"input_tokens":14,"output_tokens":2}}'
assert_equal "${SF_TUI_IDENTITY} · 14 ↑ 2 ↓" "$SF_TUI_FOOTER"
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT == *part* ]] || fail 'the turn did not reach the viewport'
[[ ${SF_TUI_VIEWPORT_TEXT//part } != *part* ]] ||
  fail 'the durable record repeated the streamed text'

# Hold the turn for a permission decision.
pump '{"type":"_tool_permission_request","id":"permission_1","tool":{"name":"shell","input":{"command":"pwd"}},"access":{"unrestricted":true},"reason":"host access","timeout":30,"reviewing":true}'
assert_equal $(( SECONDS + 30 )) "$SF_TUI_PERMISSION_DEADLINE"
assert_equal permission "$SF_TUI_STATE"
assert_equal permission_1 "$SF_TUI_PERMISSION_ID"
assert_equal shell "$SF_TUI_PERMISSION_TOOL"
assert_equal $'Operation:\n{"command":"pwd"}\nAccess:\nUnrestricted (this call only)\nReason: host access' "$SF_TUI_PERMISSION_TEXT"
assert_equal bypass "$SF_TUI_PERMISSION_KIND"
if sf_tui_answer_permission approve_session; then
  fail 'the TUI accepted unrestricted session approval'
fi
assert_equal 'checking…' "$SF_TUI_PERMISSION_REVIEW"
pump '{"type":"hook_result","lifecycle":"permission_request","id":"review_1","user_text":"Review completed."}'
assert_equal permission "$SF_TUI_STATE"
pump '{"type":"_tool_permission_review","id":"expired","decision":"deny","reason":"stale"}'
assert_equal 'checking…' "$SF_TUI_PERMISSION_REVIEW"
assert_equal deny "$SF_TUI_PERMISSION_DEFAULT"
pump '{"type":"_tool_permission_review","id":"permission_1","decision":"approve","reason":"authorized"}'
assert_equal 'approve: authorized' "$SF_TUI_PERMISSION_REVIEW"
pump '{"type":"_tool_permission_update","id":"expired","decision":"approve","timeout":10}'
assert_equal deny "$SF_TUI_PERMISSION_DEFAULT"
pump '{"type":"_tool_permission_update","id":"permission_1","decision":"approve","timeout":10}'
assert_equal approve "$SF_TUI_PERMISSION_DEFAULT"
assert_equal $(( SECONDS + 10 )) "$SF_TUI_PERMISSION_DEADLINE"
functions[sf_tui_transport_reply_saved]=$functions[sf_tui_transport_reply]
typeset held_reply=''
sf_tui_transport_reply() { held_reply="$*"; }
sf_tui_hold_permission
assert_equal 'permission_1 hold' "$held_reply"
pump '{"type":"_tool_permission_end","id":"expired"}'
assert_equal permission "$SF_TUI_STATE"
functions[sf_tui_transport_reply]=$functions[sf_tui_transport_reply_saved]
unfunction sf_tui_transport_reply_saved

# Later activity closes an expired request.
pump '{"type":"tool_result","id":"call_1","name":"shell","input":{"command":"pwd"},"exit_code":126,"model_text":"sandbox access approval timed out","user_text":"Shell pwd\nsandbox access approval timed out"}'
assert_equal working "$SF_TUI_STATE"
assert_equal '' "$SF_TUI_PERMISSION_ID"
assert_equal 0 "$SF_TUI_PERMISSION_DEADLINE"

# Capture a handoff request.
SF_TUI_STATE=working
SF_TUI_PERMISSION_ID=''
pump '{"type":"_handoff","argv":["/tmp/custom command","","arg"]}'
assert_equal '/tmp/custom command,,arg' "${(j:,:)SF_TUI_HANDOFF}"

# Apply session updates.
pump "$(jq -c '
  {type:"_session_update",profile,model:(.model | .provider = "/updated" |
    .request.model = "new-model" | .context_window = null)}
' "$SF_TEST_SESSIONS/header_only.jsonl")"
assert_equal updated/new-model "$SF_TUI_IDENTITY"
assert_equal updated/new-model "$SF_TUI_FOOTER"

# Ignore live state records without disturbing the turn.
SF_TUI_STATE=working
pump '{"type":"state_update","name":"live/status","value":"ready"}'
assert_equal working "$SF_TUI_STATE"

# Cancel active turns.
typeset -gi cancel_signals=0 cancel_stops=0
functions[sf_tui_transport_cancel_saved]=$functions[sf_tui_transport_cancel]
functions[sf_tui_transport_stop_saved]=$functions[sf_tui_transport_stop]
sf_tui_transport_cancel() { (( ++cancel_signals )) }
sf_tui_transport_stop() { (( ++cancel_stops )) }
SF_TUI_STATE=working
SF_TUI_QUEUE=( queued )
sf_tui_cancel
assert_equal cancelling "$SF_TUI_STATE"
assert_equal 1 "$cancel_signals"
assert_equal 0 "$cancel_stops"
assert_equal queued "${(j:,:)SF_TUI_QUEUE}"

# Steering cancels once and sends the draft ahead of the queue.
SF_TUI_HISTORY=()
cancel_signals=0
SF_TUI_STATE=working
SF_TUI_STEER=0
SF_TUI_QUEUE=( later )
BUFFER=now
CURSOR=3
sf_tui_steer
assert_equal cancelling "$SF_TUI_STATE"
assert_equal 1 "$cancel_signals"
assert_equal 1 "$SF_TUI_STEER"
assert_equal now,later "${(j:,:)SF_TUI_QUEUE}"
assert_equal '' "$BUFFER"
assert_equal 0 "$CURSOR"
assert_equal now "$SF_TUI_HISTORY[-1]"
# Steering after Ctrl-C keeps the existing cancellation.
BUFFER=again
sf_tui_steer
assert_equal cancelling "$SF_TUI_STATE"
assert_equal 1 "$cancel_signals"
assert_equal again,now,later "${(j:,:)SF_TUI_QUEUE}"
# Nothing to send leaves the turn running.
SF_TUI_STATE=working
SF_TUI_STEER=0
SF_TUI_QUEUE=()
BUFFER=''
sf_tui_steer
assert_equal working "$SF_TUI_STATE"
assert_equal 0 "$SF_TUI_STEER"
assert_equal 1 "$cancel_signals"
# A permission prompt hides the draft, which is sent rather than restored.
SF_TUI_STATE=permission
SF_TUI_PERMISSION_DRAFT=hidden
SF_TUI_PERMISSION_CURSOR=6
sf_tui_steer
assert_equal cancelling "$SF_TUI_STATE"
assert_equal hidden "${(j:,:)SF_TUI_QUEUE}"
assert_equal '' "$BUFFER"
SF_TUI_QUEUE=()
SF_TUI_STEER=0

functions[sf_tui_transport_cancel]=$functions[sf_tui_transport_cancel_saved]
functions[sf_tui_transport_stop]=$functions[sf_tui_transport_stop_saved]
unfunction sf_tui_transport_cancel_saved sf_tui_transport_stop_saved

# Invalid core output stops the client without retracting scrollback.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=working
sf_tui_action message_start agent
sf_tui_action message_delta 0 text $'committed\nnext\n' ''
sf_tui_transcript 20 20
sf_tui_terminal_stage
sf_tui_terminal_finish
typeset committed=$PREDISPLAY
sf_tui_terminal_restore
SF_TUI_QUEUE=( queued )
sf_tui_transport_reset
exec {SF_TUI_TRANSPORT_OUTPUT_FD}< <(print -r -- broken)
sf_tui_turn_ready "$SF_TUI_TRANSPORT_OUTPUT_FD"
assert_equal working "$SF_TUI_STATE"
sf_tui_heartbeat_tick
assert_equal stopped "$SF_TUI_STATE"
assert_equal 'turn sent invalid JSONL' "$SF_TUI_ERROR"
assert_equal 0 "${#SF_TUI_QUEUE}"
[[ $committed == *committed* ]] || fail 'committed rows were never written'
[[ $PREDISPLAY == *'Shellfish stopped: turn sent invalid JSONL'* ]] ||
  fail 'the stopped view did not report the failure'
[[ $PREDISPLAY == *'/refresh'* && $PREDISPLAY == *'/quit'* ]] ||
  fail 'the stopped view did not say which prompts it accepts'

# Preserve stopped state at EOF.
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
sf_tui_heartbeat_tick
assert_equal stopped "$SF_TUI_STATE"

# Restrict stopped prompts.
sf_tui_submit 'what happened?'
assert_equal ignore "$REPLY"
assert_equal '' "$SF_TUI_ACTION"
sf_tui_submit /refresh
assert_equal quit "$REPLY"
assert_equal handoff "$SF_TUI_ACTION"
assert_equal "$SF_ENTRY --clear --session $tmp/recover.jsonl" \
  "${(j: :)SF_TUI_HANDOFF}"
SF_TUI_ACTION=''
SF_TUI_HANDOFF=()
sf_tui_submit /q
assert_equal quit "$SF_TUI_ACTION"
SF_TUI_ACTION=''
SF_TUI_STATE=idle
SF_TUI_ERROR=''

# Start the next queued turn.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_STATE=working
SF_TUI_QUEUE=( first second )
SF_TUI_HANDOFF=()
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_turn_finish
assert_equal queued "$SF_TUI_STATE"
assert_equal first "$SF_TUI_SUBMITTED"
assert_equal second "$SF_TUI_QUEUE[1]"

# Cancellation keeps pending prompts without starting another turn.
for code in 0 130; do
  sf_tui_reset
  sf_tui_terminal_reset
  sf_tui_activity_start
  SF_TUI_SESSION="$tmp/recover.jsonl"
  SF_TUI_STATE=cancelling
  SF_TUI_STEER=0
  SF_TUI_QUEUE=( first second )
  SF_TUI_TRANSPORT_EOF=1
  SF_TUI_TRANSPORT_EXIT_STATUS=$code
  SF_TUI_TRANSPORT_EXIT_DETAIL=''
  sf_tui_turn_finish
  assert_equal idle "$SF_TUI_STATE"
  assert_equal first,second "${(j:,:)SF_TUI_QUEUE}"
  sf_tui_transcript 79 20
  [[ $SF_TUI_VIEWPORT_TEXT != *Discarded* ]] ||
    fail "cancellation reported a discarded queue: $SF_TUI_VIEWPORT_TEXT"
done

# A steered cancellation sends the next prompt and keeps the rest queued.
for code in 0 130; do
  sf_tui_reset
  sf_tui_terminal_reset
  sf_tui_activity_start
  SF_TUI_SESSION="$tmp/recover.jsonl"
  SF_TUI_STATE=cancelling
  SF_TUI_STEER=1
  SF_TUI_QUEUE=( now later )
  SF_TUI_TRANSPORT_EOF=1
  SF_TUI_TRANSPORT_EXIT_STATUS=$code
  SF_TUI_TRANSPORT_EXIT_DETAIL=''
  sf_tui_turn_finish
  assert_equal queued "$SF_TUI_STATE"
  assert_equal now "$SF_TUI_SUBMITTED"
  assert_equal later "${(j:,:)SF_TUI_QUEUE}"
  assert_equal 0 "$SF_TUI_STEER"
done
# An uncertain cancellation discards the queue without continuing.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=cancelling
SF_TUI_STEER=1
SF_TUI_QUEUE=( now )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='provider failed'
sf_tui_turn_finish
assert_equal idle "$SF_TUI_STATE"
assert_equal 0 "${#SF_TUI_QUEUE}"
assert_equal 0 "$SF_TUI_STEER"
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT == *'Discarded 1 queued prompt'* ]] ||
  fail "uncertain cancellation hid the discarded queue: $SF_TUI_VIEWPORT_TEXT"

# Cancelling session creation discards the queue with a notice.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/created.jsonl"
SF_TUI_CREATING=1
SF_TUI_STATE=cancelling
SF_TUI_QUEUE=( early )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=130
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_turn_finish
assert_equal stopped "$SF_TUI_STATE"
assert_equal 0 "${#SF_TUI_QUEUE}"
[[ $SF_TUI_ERROR == *'Discarded 1 queued prompt'* ]] ||
  fail "cancelled creation hid the discarded queue: $SF_TUI_ERROR"

# Discard queues after uncertain exits.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=working
SF_TUI_QUEUE=( speculative )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='provider failed'
sf_tui_turn_finish
assert_equal 0 "${#SF_TUI_QUEUE}"
assert_equal idle "$SF_TUI_STATE"

# Keep the draft hidden by a permission prompt when the turn fails.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=permission
SF_TUI_PERMISSION_DRAFT=draft
SF_TUI_PERMISSION_CURSOR=2
BUFFER=''
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='provider failed'
sf_tui_turn_finish
assert_equal idle "$SF_TUI_STATE"
assert_equal draft "$BUFFER"
assert_equal 2 "$CURSOR"

# A durable failure is reported by the core, so the client adds no heading of
# its own. Rows committed during the tick have already left the queue.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=working
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=( '{"type":"error","user_text":"test provider failure"}' )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='test provider failure'
sf_tui_heartbeat_tick
assert_equal idle "$SF_TUI_STATE"
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT != *'Turn failed'* ]] ||
  fail "a settled error was reported twice: $SF_TUI_VIEWPORT_TEXT"

# Recover from terminated execs.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=working
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=143
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_turn_finish
assert_equal idle "$SF_TUI_STATE"
sf_tui_submit next
assert_equal submit "$REPLY"
assert_equal next "$SF_TUI_SUBMITTED"

# A blocked prompt displays hook output, but never becomes a user message.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_STATE=idle
sf_tui_submit /help
assert_equal submit "$REPLY"
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT != *'/help'* ]] ||
  fail 'submitted prompt rendered before the core accepted it'
assert_equal '' "$SF_TUI_LAST_SECTION"
SF_TUI_STATE=working
pump '{"type":"hook_result","lifecycle":"user_prompt_submit","id":"1","user_text":"Help notice"}'
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT == *'Help notice'* && $SF_TUI_VIEWPORT_TEXT != *'─ user '* &&
    $SF_TUI_VIEWPORT_TEXT != *'/help'* ]] ||
  fail 'blocked prompt claimed a numbered section'
assert_equal '' "$SF_TUI_LAST_SECTION"
# The accepted prompt owns the section assigned by the core.
pump '{"type":"user","section":12,"content":[{"type":"text","text":"accepted"}]}'
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT == *'Help notice'*'accepted'* ]] ||
  fail 'accepted prompt did not render from the core record'
assert_equal 12 "$SF_TUI_LAST_SECTION"

# Stop on failed permission replies.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=permission
SF_TUI_PERMISSION_ID=permission_1
functions[sf_tui_transport_reply_saved]=$functions[sf_tui_transport_reply]
sf_tui_transport_reply() { return 1 }
if sf_tui_answer_permission approve; then
  fail 'an undeliverable decision was accepted'
fi
functions[sf_tui_transport_reply]=$functions[sf_tui_transport_reply_saved]
unfunction sf_tui_transport_reply_saved
assert_equal stopped "$SF_TUI_STATE"
assert_equal 'cannot answer permission' "$SF_TUI_ERROR"
assert_equal '' "$SF_TUI_PERMISSION_ID"
SF_TUI_STATE=idle
SF_TUI_ERROR=''

# Run queued client commands.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_SESSION="$tmp/recover.jsonl"
SF_TUI_STATE=working
SF_TUI_ACTION=''
SF_TUI_HANDOFF=()
SF_TUI_QUEUE=( /refresh )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_turn_finish
assert_equal handoff "$SF_TUI_ACTION"
assert_equal "$SF_ENTRY --clear --session $tmp/recover.jsonl" \
  "${(j: :)SF_TUI_HANDOFF}"
SF_TUI_ACTION=''
SF_TUI_HANDOFF=()

# Creation names the session and renders its system context before live hooks.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_PROJECT_MODE=live
SF_TUI_SESSION=''
SF_TUI_STATE=working
SF_TUI_QUEUE=()
sf_tui_submit early
assert_equal repaint "$REPLY"
assert_equal early "${(j:,:)SF_TUI_QUEUE}"
pump "$(jq -cn --arg path "$tmp/new.jsonl" '{type:"_session_load",path:$path}')" \
  '{"type":"session","profile":{"system":[{"text":"instructions"}]},"model":{"provider":"/test","request":{"model":"model"}}}' \
  '{"type":"_draft","lifecycle":"session_start","id":"1","user_text":"setup · working"}'
assert_equal working "$SF_TUI_STATE"
assert_equal "$tmp/new.jsonl" "$SF_TUI_SESSION"
assert_equal "$SF_ENTRY run --jsonl --session $tmp/new.jsonl" \
  "${(j: :)SF_TUI_TRANSPORT_COMMAND}"
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT == *instructions*'setup · working'* ]] ||
  fail 'startup did not render system context before live hook activity'
pump '{"type":"hook_result","lifecycle":"session_start","id":"1","user_text":"setup · ready"}'
sf_tui_transcript 79 20
[[ $SF_TUI_VIEWPORT_TEXT == *instructions*'setup · ready'* &&
    $SF_TUI_VIEWPORT_TEXT != *'setup · working'* ]] ||
  fail 'startup hook activity did not settle in place'
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_turn_finish
assert_equal queued "$SF_TUI_STATE"
assert_equal early "$SF_TUI_SUBMITTED"

# Stop failed session creation.
typeset code
for code in 0 9; do
  sf_tui_reset
  sf_tui_terminal_reset
  SF_TUI_SESSION=''
  (( ! code )) || SF_TUI_SESSION="$tmp/failed.jsonl"
  SF_TUI_CREATING=1
  SF_TUI_STATE=working
  SF_TUI_QUEUE=()
  SF_TUI_TRANSPORT_EOF=1
  SF_TUI_TRANSPORT_EXIT_STATUS=$code
  SF_TUI_TRANSPORT_EXIT_DETAIL='startup failure'
  sf_tui_turn_finish
  assert_equal stopped "$SF_TUI_STATE"
  [[ $SF_TUI_ERROR == 'Session creation failed.'* ]] ||
    fail "creation failure reported $SF_TUI_ERROR"
  assert_equal '' "$SF_TUI_SESSION"
  [[ $POSTDISPLAY != *'[r]'* ]] || fail 'refresh was offered without a session'
done

# Image markers attach readable images in order; other markers stay text only.
typeset png=iVBORw0KGgoAAAANSUhEUgAAAAQAAAACAQMAAABFZu8gAAAAA1BMVEUAgACc+aWRAAAADElEQVQI12NgYGAAAAAEAAEnNCcKAAAAAElFTkSuQmCC
print -rn -- $png | base64 -d >"$tmp/shot"
print -rn -- $'\xff\xd8\xff\xe0 jpeg' >"$tmp/photo"
print -r -- 'not an image' >"$tmp/notes"
typeset prompt="Compare [Image: $tmp/shot] with [Image: $tmp/photo], [Image: $tmp/notes], and [Image: $tmp/gone]"
sf_tui_user_record "$prompt" | jq -e --arg prompt "$prompt" --arg png "$png" '
  . == {type:"user",content:[{type:"text",text:$prompt},
    {type:"image",url:("data:image/png;base64," + $png)},
    {type:"image",url:"data:image/jpeg;base64,/9j/4CBqcGVn"}]}
' >/dev/null || fail 'image markers did not attach their images'
sf_tui_user_record 'plain [Image: words' |
  jq -e '. == {type:"user",content:[{type:"text",text:"plain [Image: words"}]}' >/dev/null ||
  fail 'a prompt without complete markers gained content'

print -r -- ok
