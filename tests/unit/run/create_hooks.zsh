#!/usr/bin/env zsh
source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/jq.zsh
sf_test_tmp run-create-hook-contract
sf_test_config
typeset entry="$ROOT/bin/shellfish" hook="$SF_TEST_CONFIG/hooks/project/instructions"
typeset project="$tmp/project" session="$tmp/session.jsonl" stream="$tmp/stream"
mkdir -p "$hook" "$project"
cp "$ROOT/share/hooks/project/instructions/"{manifest.json,run} "$hook/"
print -r -- 'Follow this project rule.' >"$project/AGENTS.md"
sf_test_model default "{\"provider\":\"$ROOT/tests/fixtures/provider\",\"request\":{\"model\":\"test\"}}"
sf_test_profile default '{"hooks":["project/instructions"]}'
export SHELLFISH_MAX_CAPTURE_BYTES=1024
(cd "$project" && zsh -f "$entry" run --jsonl --session-create --session-out "$session") \
  >"$stream" || fail 'manifested session_start hook failed'
jq -eRn --arg session "$session" --arg hook "${hook:A}" '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","hook_result"] and
  $events[0] == {type:"_session_load",path:$session} and
  $events[1].profile.hooks == [$hook] and
  ($events[2] | .lifecycle == "session_start" and
    .user_text == "**Project instructions** (AGENTS.md)\nFollow this project rule.\n" and
    (.model_text | contains("<context script=\"project/instructions\">")))
' <"$stream" >/dev/null || fail 'hook settlement was wrong'
assert_canonical_session "$session"
create() {
  local destination=$1
  shift
  (cd "$project" && zsh -f "$entry" run --jsonl --session-create --session-out "$destination" "$@") \
    >"$stream"
}
reject() {
  local expected=$1
  shift
  integer code=0
  session="$tmp/rejected.jsonl"
  rm -f "$session"
  create "$session" "$@" 2>"$tmp/rejected.stderr" || code=$?
  (( code == 1 )) && [[ $(<"$tmp/rejected.stderr") == *"$expected"* ]] ||
    fail "expected creation failure: $expected"
}
# Run one presentation contract through both public compositions.
sf_test_frozen_profile
export SHELLFISH_MAX_CAPTURE_BYTES=1024
typeset kind scenario manifest result_type
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
case $COMPONENT_CASE in
  protocol)
    print -r -u3 -- '{"state_update":[{"name":"component/a","value":1}]}'
    print -r -u3 -- '{"state_update":[{"name":"component/b","value":2}]}'
    print -rn -- 'literal ${input}'
    print -rn -u2 -- 'stderr'
    [[ $COMPONENT_KIND != tool ]] || exit 4
    ;;
  capture|capture_override)
    if [[ $COMPONENT_CASE == capture_override ]]; then
      [[ $SHELLFISH_MAX_CAPTURE_BYTES == 2048 ]] || exit 3
    else
      [[ $SHELLFISH_MAX_CAPTURE_BYTES == 1024 ]] || exit 3
    fi
    print -rn -- 'head'${(l:1200::o:)}'stdout-tail'
    print -rn -u2 -- 'head'${(l:1200::e:)}'stderr-tail'
    ;;
  silent) print -rn -u2 -- 'unrendered output' ;;
esac
ZSH
for scenario in protocol capture capture_override silent; do
  case $scenario in
    protocol) manifest='{"user_text":"Running\n${output.stdout}|${output.stderr}","user_preview_lines":"full"}' ;;
    capture) manifest='{"user_text":"${output.stdout}|${output.stderr}"}' ;;
    capture_override) manifest='{"user_text":"${output.stdout}|${output.stderr}","max_capture_bytes":2048}' ;;
    silent) manifest='{}' ;;
  esac
  jq -c '{on:"session_start"} + .' <<<"$manifest" >"$hook/manifest.json"
  sf_test_shell_tool 'del(.user_text) + '"$manifest" "$hook/run"
  for kind in hook tool; do
    session="$tmp/$kind-$scenario.jsonl"
    export COMPONENT_CASE=$scenario COMPONENT_KIND=$kind
    if [[ $kind == hook ]]; then
      result_type=hook_result
      create "$session" || fail "$kind $scenario failed"
    else
      result_type=tool_result
      sf_test_session "$session"
      SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COMMAND=$scenario \
        sf_test_run component "$session" >"$stream" || fail "$kind $scenario failed"
    fi
    jq -eRn --arg scenario "$scenario" --arg kind "$kind" --arg result_type "$result_type" '
      [inputs | fromjson | select(.type | IN("_draft","state_update","hook_result","tool_result"))] as $e |
      [$e[] | select(.type == $result_type)] as $results |
      def model($text): if $kind == "hook" then
        "<context script=\"project/instructions\">\n" + $text + "\n</context>" else $text end;
      (if $kind == "tool" or $scenario != "silent" then
        ($results | length) == 1 else ($results | length) == 0 end) and
      if $scenario == "protocol" then
        [$e[].type] == ["_draft","state_update","state_update",$result_type] and
        [$e[1],$e[2]] == [{type:"state_update",name:"component/a",value:1},{type:"state_update",name:"component/b",value:2}] and
        $e[0].user_text == "Running\n|" and
        $results[0].user_text == "Running\nliteral ${input}|stderr" and
        (if $kind == "tool" then $results[0].exit_code == 4 else true end) and
        $results[0].model_text == model("literal ${input}") and
        all($e[] | select(.type != "state_update"); .user_preview_lines == "full")
      elif $scenario == "capture" then
        ($results[0].user_text | length == 2049 and contains("stdout-tail") and
          contains("stderr-tail") and (contains("head") | not)) and
        ($results[0].model_text | length == (model("") | length) + 1024) and
        ([$results[0].user_text | scan("\\[output truncated\\]")] | length) == 2
      elif $scenario == "capture_override" then
        ($results[0].user_text | contains("head") and contains("stdout-tail") and
          contains("stderr-tail") and (contains("[output truncated]") | not)) and
        ($results[0].model_text | length > 1024)
      else
        if $kind == "hook" then $e == []
        else [$e[].type] == ["tool_result"] and
          ($results[0] | has("user_text") or has("model_text") | not) end
      end
    ' <"$stream" >/dev/null || fail "$kind $scenario presentation was wrong"
    assert_canonical_session "$session"
  done
done
# Invalid fd3 lines fail without leaving a result.
typeset field
for field in '"unknown":true' '"state_update":[{"name":"invalid state","value":1}]' \
  '"state_update":[{"name":"valid/state","value":1}],"user_text":"override"'; do
  print -r -- '#!/usr/bin/env zsh' >"$hook/run"
  print -r -- "print -r -u3 -- '{$field}'" >>"$hook/run"
  reject 'returned invalid control'
  jq -e -s 'map(.type) == ["session"]' "$session" >/dev/null ||
    fail "invalid fd3 $field produced a result"
done
# Reconstruct model context after removing the live manifest.
rm "$hook/manifest.json"
session="$tmp/session.jsonl"
sf_jq -e -s '
  include "lib/profile";
  include "lib/session";
  .[1:] | session_messages[-1].content[0].text |
  contains("<context script=\"project/instructions\">") and
  contains("Follow this project rule.")
' "$session" >/dev/null || fail 'replay needed the live manifest'
reject 'hook manifest must be valid and declare "on"'
typeset invalid
for invalid in field template capture lifecycle unbound; do
  case $invalid in
    field) print -r -- '{"on":"session_start","description":"not a hook field"}' >"$hook/manifest.json" ;;
    template) print -r -- '{"on":"session_start","user_text":"${input.undeclared}"}' >"$hook/manifest.json" ;;
    capture) print -r -- '{"on":"session_start","max_capture_bytes":63}' >"$hook/manifest.json" ;;
    lifecycle) print -r -- '{"on":"session_end"}' >"$hook/manifest.json" ;;
    unbound) print -r -- '{}' >"$hook/manifest.json" ;;
  esac
  reject 'hook manifest must be valid and declare "on"'
done
print -r -- ok
