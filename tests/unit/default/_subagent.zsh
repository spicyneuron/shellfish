# Shared subagent fixtures.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-tools-subagent
sf_test_config

typeset agent="$ROOT/share/tools/subagent"
typeset provider="$tmp/provider" session="$tmp/parent.jsonl" stream="$tmp/stream"
mkdir -p "$provider"
print -r -- '{"endpoint":"https://example.invalid/test"}' >"$provider/manifest.json"
cat >"$provider/run" <<'ZSH'
#!/usr/bin/env zsh
say() { jq -cn --arg text "$1" '{type:"assistant",stop:"end",content:[{type:"text",text:$text}]}'; }
call() {
  jq -cn --argjson input "$1" \
    '{type:"assistant",stop:"tool_calls",content:[{type:"tool_call",id:"call_1",name:"subagent",input:$input}]}'
}
request=$(cat)
task=$(jq -r '[.messages[] | select(.type == "user") | .content[0].text] | last' <<<"$request")
if [[ $task == 'delegated task' ]]; then
  print -r -- "$request" >"$SF_AGENT_REQUEST"
  say 'fork answer'
  exit 0
fi
if jq -e '.tools | any(.name == "subagent")' <<<"$request" >/dev/null; then
  if [[ $task == 'inspect child' || $task == 'continue child' ||
        $task == 'continue background' ]] && jq -e '
      ([.messages | to_entries[] | select(.value.type == "user" and
        .value.content[0].text == $task) | .key] | last) as $turn |
      $turn != null and
      ([.messages[$turn + 1:][] | select(.type == "tool_result")] | length) == 0
    ' --arg task "$task" <<<"$request" >/dev/null; then
    id=$(<"$SF_AGENT_ID_FILE")
    if [[ $task == 'inspect child' ]]; then
      input=$(jq -cn --arg id "$id" '{operation:"inspect",agent_id:$id}')
    else
      input=$(jq -cn --arg id "$id" \
        --arg task "$([[ $task == 'continue background' ]] && print 'slow child' || print 'next child task')" \
        --argjson background "$([[ $task == 'continue background' ]] && print true || print false)" \
        '{operation:"continue",agent_id:$id,task:$task,background:$background}')
    fi
    call "$input"
  elif jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
    say 'parent done'
  elif [[ $task == 'background parent' ]]; then
    call '{"operation":"start","profile":"child","task":"slow child","background":true}'
  elif [[ $task == 'stop-hook parent' ]]; then
    call '{"operation":"start","profile":"child-stop","task":"child task"}'
  elif [[ $task == 'fork parent' || $task == 'fork header' ]]; then
    call '{"operation":"start","fork":true,"task":"delegated task"}'
  else
    [[ $task != 'parent failure' ]] || task='child error'
    [[ $task == 'child error' ]] || task='child task'
    call "$(jq -cn --arg task "$task" '{operation:"start",profile:"child",task:$task}')"
  fi
else
  if [[ $task == 'slow child' ]]; then
    integer deadline=$(( SECONDS + 12 ))
    until [[ -e $SF_AGENT_RELEASE ]]; do
      (( SECONDS < deadline )) || exit 1
      sleep 0.02
    done
  fi
  if jq -e '[.messages[] | select(.type == "user") | .content[0].text] |
      last == "child error"' <<<"$request" >/dev/null; then
    exit 7
  fi
  say 'child answer'
fi
ZSH
chmod +x "$provider/run"
# The child profile names this tool, which a subagent must not receive.
sf_test_profile child "{\"tools\":[\"$agent\"]}"
sf_test_model alt "$(jq -cn --arg provider "$provider" \
  '{provider:$provider,endpoint:"https://example.invalid/test",request:{model:"alt-model"}}')"
sf_test_hook "$tmp/stop-hook" '{"on":"stop","user_text":"${output.stderr}"}' <<'ZSH'
#!/usr/bin/env zsh
if [[ ${SF_AGENT_STOP_DENY-} == 1 && $1 == 1 ]]; then
  print -r -- 'Try again'
  print -r -u3 -- '{"action":"deny"}'
fi
print -r -u2 -- 'Checks passed'
ZSH
sf_test_profile child-stop "{\"hooks\":[\"$tmp/stop-hook\"]}"

sf_test_frozen_profile
SF_TEST_MODEL=$(jq -c --arg provider "$provider" '.provider=$provider' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c --arg tool "$agent" '.tools=[$tool] |
  .config.subagent={profiles:{child:"Test child","child-stop":"Test child with a stop hook"},
    models:{alt:"Alternate test model"}}' <<<"$SF_TEST_PROFILE")
