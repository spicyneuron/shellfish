#!/usr/bin/env zsh
source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/jq.zsh
sf_test_tmp run-create-hook-contract
sf_test_config
export XDG_STATE_HOME="$tmp/state"
typeset entry="$ROOT/bin/shellfish" hook="$SF_TEST_CONFIG/hooks/project/instructions"
typeset project="$tmp/project" session="$tmp/session.jsonl" stream="$tmp/stream"
mkdir -p "$hook" "$project"
cp "$ROOT/share/hooks/project/instructions/"{manifest.json,run} "$hook/"
print -r -- 'Follow this project rule.' >"$project/AGENTS.md"
sf_test_profile default "{
  \"backend\":{\"adapter\":\"$ROOT/tests/fixtures/backend\"},
  \"request\":{\"model\":\"test\"},
  \"tools\":[],\"sandbox\":false,
  \"hooks\":{\"session_start\":[\"project/instructions\"]},
  \"max_capture_bytes\":1024
}"
(cd "$project" && zsh -f "$entry" run --jsonl --session-create --session-out "$session") \
  >"$stream" || fail 'manifested session_start hook failed'
jq -eRn --arg session "$session" --arg hook "${hook:A}" '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","_draft","hook_result"] and
  $events[0] == {type:"_session_load",path:$session} and
  $events[1].profile.hooks.session_start == [$hook] and
  ($events[2] | .lifecycle == "session_start" and
    .user_text == "Loading AGENTS.md…") and
  ($events[3] | .lifecycle == "session_start" and
    .user_text == "Project instructions (AGENTS.md):\nFollow this project rule.\n" and
    (.model_text | contains("<context script=\"project/instructions\">")))
' <"$stream" >/dev/null || fail 'hook draft, name, or settlement was wrong'
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
SF_TEST_PROFILE=$(jq -c '.max_capture_bytes=1024' <<<"$SF_TEST_PROFILE")
typeset kind scenario manifest result_type component_name
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
case $COMPONENT_CASE in
  protocol)
    print -r -u3 -- '{"state":[{"name":"component/a","value":1}],"data":{"tag":"old"},"user_text":"Working ${data.tag}"}'
    print -r -u3 -- '{"state":[{"name":"component/b","value":2}],"data":{"tag":"${literal}"},"user_text":"Shown ${data.tag}","user_text_done":"${data.tag}: ${output.stdout}|${output.stderr}/${output.exit_code}","model_text":"${output.stdout}"}'
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
  silent)
    print -r -u3 -- '{"user_text":"Working","user_text_done":"","model_text":""}'
    print -rn -- 'unrendered output'
    ;;
esac
ZSH
for scenario in protocol capture capture_override silent manifest_silent null; do
  case $scenario in
    protocol) manifest='{"user_text":"Running ${name}","user_text_done":"Finished","user_preview_lines":"full","model_text":""}' ;;
    capture) manifest='{"user_text":"","user_text_done":"${output.stdout}|${output.stderr}","model_text":"${output.stdout}${output.stderr}"}' ;;
    capture_override) manifest='{"user_text":"","user_text_done":"${output.stdout}|${output.stderr}","model_text":"${output.stdout}${output.stderr}","max_capture_bytes":2048}' ;;
    silent) manifest='{"user_text":"","user_text_done":"","model_text":""}' ;;
    manifest_silent) manifest='{"user_text":"Working","user_text_done":"","model_text":""}' ;;
    null) manifest='{"user_text":null,"user_text_done":null,"user_text_skipped":null,"model_text":null}' ;;
  esac
  print -r -- "$manifest" >"$hook/manifest.json"
  sf_test_shell_tool '. + '"$manifest" "$hook/run"
  for kind in hook tool; do
    session="$tmp/$kind-$scenario.jsonl"
    export COMPONENT_CASE=$scenario COMPONENT_KIND=$kind
    if [[ $kind == hook ]]; then
      result_type=hook_result component_name=project/instructions
      create "$session" || fail "$kind $scenario failed"
    else
      result_type=tool_result component_name=shell
      sf_test_session "$session"
      SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=$scenario \
        sf_test_run component "$session" >"$stream" || fail "$kind $scenario failed"
    fi
    jq -eRn --arg scenario "$scenario" --arg kind "$kind" \
      --arg result_type "$result_type" --arg name "$component_name" '
      [inputs | fromjson | select(.type | IN("_draft","state","hook_result","tool_result"))] as $e |
      [$e[] | select(.type == $result_type)] as $results |
      (if $kind == "tool" or ($scenario | IN("protocol","capture","capture_override")) then
        ($results | length) == 1 else ($results | length) == 0 end) and
      if $scenario == "protocol" then
        [$e[].type] == ["_draft","state","_draft","state","_draft",$result_type] and
        [$e[1],$e[3]] == [{type:"state",name:"component/a",value:1},{type:"state",name:"component/b",value:2}] and
        [$e[0].user_text,$e[2].user_text,$e[4].user_text] == ["Running " + $name,"Working old","Shown ${literal}"] and
        $results[0].user_text == ("${literal}: literal ${input}|stderr/" +
          if $kind == "tool" then "4" else "0" end) and
        (if $kind == "tool" then $results[0].exit_code == 4 else true end) and
        $results[0].model_text == "literal ${input}" and
        all($e[] | select(.type != "state"); .user_preview_lines == "full")
      elif $scenario == "capture" then
        ($results[0].user_text | length == 2049 and contains("stdout-tail") and
          contains("stderr-tail") and (contains("head") | not)) and
        ($results[0].model_text | length == 2048) and
        ([$results[0].user_text | scan("\\[output truncated\\]")] | length) == 2
      elif $scenario == "capture_override" then
        ($results[0].user_text | contains("head") and contains("stdout-tail") and
          contains("stderr-tail") and (contains("[output truncated]") | not)) and
        ($results[0].model_text | length > 2048)
      elif $scenario == "silent" or $scenario == "manifest_silent" then
        $e[0].user_text == "Working" and
        if $kind == "hook" then ($results | length) == 0 and $e[-1].user_text == ""
        else ($results | length) == 1 and ($results[0] | has("user_text") or has("model_text") | not) end
      else
        if $kind == "hook" then $e == []
        else $e[0].user_text == "shell {\"command\":\"null\"}" and
          $results[0].user_text == "shell {\"command\":\"null\"}\n" and
          ($results[0] | has("model_text") | not) end
      end
    ' <"$stream" >/dev/null || fail "$kind $scenario presentation was wrong"
    assert_canonical_session "$session"
  done
done
# Absolute references keep the relative name under the configured root and the
# absolute name elsewhere, even under another /hooks/ directory.
typeset external="$tmp/external/hooks/probe" reference name
print -r -- '#!/usr/bin/env zsh' | sf_test_hook "$external" '{"user_text_done":"${name}"}'
print -r -- '{"user_text_done":"${name}"}' >"$hook/manifest.json"
print -r -- '#!/usr/bin/env zsh' >"$hook/run"
for reference name in "$hook" project/instructions "$external" "${external:A}"; do
  sf_test_profile absolute "{\"extend\":[\"default\"],\"hooks\":{\"session_start\":[\"$reference\"]}}"
  create "$tmp/absolute-${reference:t}.jsonl" -p absolute || fail "absolute hook failed: $reference"
  jq -eRn --arg name "$name" '
    [inputs | fromjson | select(.type == "hook_result")][0].user_text == $name
  ' <"$stream" >/dev/null || fail "absolute hook rendered the wrong name: $reference"
done
# Invalid fd3 lines fail without leaving a result.
typeset field
for field in '"unknown":true' '"state":[{"name":"invalid state","value":1}]' \
  '"state":[{"name":"valid/state","value":1}],"data":{"note":1}' \
  '"data":{"bad-key":"value"}' '"user_text_done":"${output.unknown}"'; do
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
reject 'cannot read component manifest'
typeset invalid
for invalid in field template capture; do
  case $invalid in
    field) print -r -- '{"description":"not a hook field"}' >"$hook/manifest.json" ;;
    template) print -r -- '{"user_text_done":"${input.undeclared}"}' >"$hook/manifest.json" ;;
    capture) print -r -- '{"max_capture_bytes":63}' >"$hook/manifest.json" ;;
  esac
  reject 'invalid hook manifest'
done
print -r -- ok
