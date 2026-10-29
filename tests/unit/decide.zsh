#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp decide

typeset entry="$ROOT/bin/shellfish" result request invalid model
typeset adapter=${SF_TEST_BACKEND:h}
model=$(jq -cn --arg adapter "$adapter" \
  '{adapter:$adapter,config:{http_timeout:60},request:{model:"fake-decider"}}')
request=$(jq -cn '{
  system:"Judge carefully.",
  input:[{type:"text",text:"A clip."},{type:"json",data:{frames:2}},
    {type:"image",url:"data:image/png;base64,AAAA"},{type:"video",url:"https://example.invalid/a.mp4"}],
  questions:{
    moved:{type:"predicate",instructions:"Did it move?",criteria:{true:"Any motion."}},
    direction:{type:"choice",instructions:"Which way?",choices:{right:null,left:"Leftward."}},
    risk:{type:"score",instructions:"How risky?",levels:["low","medium","high"]},
    secret:{type:"predicate",instructions:"refuse"}}}')

result=$(SF_TEST_BACKEND_REQUEST="$tmp/request.json" \
  zsh -f "$entry" decide -m "$model" <<<"$request") || fail 'decide failed'
jq -e '
  .model == "fake-decider" and (.usage.output_tokens == 0) and .answers == {
    moved:{type:"predicate",probability:0.75},
    direction:{type:"choice",choice:"right",confidence:1,probabilities:{right:1,left:0}},
    risk:{type:"score",score:1,confidence:1,probabilities:[0,1,0]},
    secret:{type:"refusal"}}
' <<<"$result" >/dev/null || fail 'decide produced the wrong result' "$result"
jq -e --argjson decision "$request" '
  .format_version == 1 and .system == $decision.system and .input == $decision.input and
  .questions == $decision.questions and .request == {model:"fake-decider"} and
  .endpoint == "https://example.invalid/test" and .config == {http_timeout:60}
' "$tmp/request.json" >/dev/null || fail 'decide sent the wrong adapter request'

# Inline media larger than the argument limit reaches the adapter intact.
head -c 1572864 /dev/zero | base64 | tr -d '\n' | jq -Rc --argjson request "$request" '
  . as $data | $request | .input = [{type:"video",url:("data:video/mp4;base64," + $data)}]
' >"$tmp/large.json"
SF_TEST_BACKEND_REQUEST="$tmp/large-request.json" \
  zsh -f "$entry" decide -m "$model" <"$tmp/large.json" >/dev/null 2>"$tmp/large.err" ||
  fail 'decide failed on large media' "$(<"$tmp/large.err")"
jq -e --slurpfile sent "$tmp/large.json" '.input == $sent[0].input' "$tmp/large-request.json" \
  >/dev/null || fail 'decide altered large media'

# An omitted system arrives empty.
SF_TEST_BACKEND_REQUEST="$tmp/no-system.json" zsh -f "$entry" decide -m "$model" \
  <<<"$(jq -c 'del(.system)' <<<"$request")" >/dev/null
jq -e '.system == ""' "$tmp/no-system.json" >/dev/null

zsh -f "$entry" decide <<<"$request" >/dev/null 2>"$tmp/no-model.err" &&
  fail 'decide ran without a model'
[[ $(<"$tmp/no-model.err") == *'decide requires --model'* ]]
zsh -f "$entry" decide -m "$model" extra <<<"$request" >/dev/null 2>&1 &&
  fail 'decide accepted a positional argument'

# Invalid requests fail before any adapter runs.
for invalid in '' '{' '[]' "$request $request" \
    "$(jq -c '.extra = 1' <<<"$request")" \
    "$(jq -c '.system = 1' <<<"$request")" \
    "$(jq -c '.input = []' <<<"$request")" \
    "$(jq -c '.input = [{type:"audio",url:"data:,x"}]' <<<"$request")" \
    "$(jq -c '.input = [{type:"image",url:"file:///etc/passwd"}]' <<<"$request")" \
    "$(jq -c '.questions = {}' <<<"$request")" \
    "$(jq -c '.questions = {"bad name":{type:"predicate",instructions:"x"}}' <<<"$request")" \
    "$(jq -c '.questions.moved.type = "box"' <<<"$request")" \
    "$(jq -c '.questions.moved.criteria = {maybe:"x"}' <<<"$request")" \
    "$(jq -c '.questions.direction.choices = {only:null}' <<<"$request")" \
    "$(jq -c '.questions.risk.levels = ["one"]' <<<"$request")" \
    "$(jq -c 'del(.questions.risk.instructions)' <<<"$request")"; do
  rm -f -- "$tmp/rejected.json"
  if SF_TEST_BACKEND_REQUEST="$tmp/rejected.json" \
      zsh -f "$entry" decide -m "$model" <<<"$invalid" >/dev/null 2>"$tmp/invalid.err"; then
    fail "decide accepted an invalid request: $invalid"
  fi
  [[ $(<"$tmp/invalid.err") == *'invalid decision request'* ]] ||
    fail 'decide misreported an invalid request' "$(<"$tmp/invalid.err")"
  [[ ! -e $tmp/rejected.json ]] || fail 'an invalid request invoked an adapter'
done

SF_TEST_DECIDE=error zsh -f "$entry" decide -m "$model" <<<"$request" \
  >/dev/null 2>"$tmp/error.err" && fail 'decide accepted an adapter failure'
[[ $(<"$tmp/error.err") == *'test decision failure'* ]] || fail 'decide hid the adapter error'

SF_TEST_DECIDE=invalid zsh -f "$entry" decide -m "$model" <<<"$request" \
  >"$tmp/invalid.out" 2>"$tmp/invalid.err" && fail 'decide accepted an invalid result'
[[ ! -s $tmp/invalid.out ]]
[[ $(<"$tmp/invalid.err") == *'backend returned an invalid decision'* ]]

# Answers must match their questions.
typeset bad_adapter="$tmp/bad-adapter"
mkdir -p "$bad_adapter"
cp "$adapter/manifest.json" "$bad_adapter/"
cat >"$bad_adapter/decide" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- "$SF_TEST_RESULT"
ZSH
chmod +x "$bad_adapter/decide"
model=$(jq -cn --arg adapter "$bad_adapter" '{adapter:$adapter,request:{model:"bad"}}')
request='{"input":[{"type":"text","text":"x"}],"questions":{
  "p":{"type":"predicate","instructions":"x"},
  "c":{"type":"choice","instructions":"x","choices":{"a":null,"b":null}},
  "s":{"type":"score","instructions":"x","levels":["a","b"]}}}'
typeset valid='{"model":"bad","answers":{"p":{"type":"predicate","probability":0.5},
  "c":{"type":"choice","choice":"a","confidence":0.5,"probabilities":{"a":0.5,"b":0.5}},
  "s":{"type":"score","score":0.5,"confidence":0.5,"probabilities":[0.5,0.5]}}}'
SF_TEST_RESULT=$valid zsh -f "$entry" decide -m "$model" <<<"$request" >/dev/null ||
  fail 'decide rejected a valid result'
for invalid in \
    'del(.answers.p)' '.answers.x = {type:"refusal"}' '.answers.p.type = "score"' \
    '.answers.p.probability = 1.5' '.answers.c.choice = "z"' \
    '.answers.c.probabilities = {a:1}' '.answers.s.probabilities = [1]' \
    '.answers.s.score = 2' '.answers.p.extra = 1' '.usage = {input_tokens:-1,output_tokens:0}' \
    'del(.model)'; do
  SF_TEST_RESULT=$(jq -c "$invalid" <<<"$valid") zsh -f "$entry" decide -m "$model" \
    <<<"$request" >/dev/null 2>&1 && fail "decide accepted an invalid result: $invalid"
done

# A backend without a decide entrypoint cannot answer decisions.
mkdir -p "$tmp/chat-only"
ln -s "$SF_TEST_BACKEND" "$tmp/chat-only/run"
cp "$adapter/manifest.json" "$tmp/chat-only/"
model=$(jq -cn --arg adapter "$tmp/chat-only" '{adapter:$adapter,request:{model:"chat"}}')
zsh -f "$entry" decide -m "$model" <<<"$request" >/dev/null 2>"$tmp/entry.err" &&
  fail 'decide ran a backend without a decide entrypoint'
[[ $(<"$tmp/entry.err") == *'backend has no decide entrypoint'* ]]

# An interrupted decision exits with the signal status and stops its adapter.
mkdir -p "$tmp/slow"
cp "$adapter/manifest.json" "$tmp/slow/"
print -r -- $'#!/usr/bin/env zsh\ncat >/dev/null\nprint -r -- $$ >"$SF_TEST_PID"\nsleep 30' \
  >"$tmp/slow/decide"
chmod +x "$tmp/slow/decide"
model=$(jq -cn --arg adapter "$tmp/slow" '{adapter:$adapter,request:{model:"slow"}}')
SF_TEST_PID="$tmp/slow.pid" zsh -f "$entry" decide -m "$model" <<<"$request" >/dev/null 2>&1 &
typeset decide_pid=$! interrupt_status=0
integer polls=0
until [[ -s $tmp/slow.pid ]] || (( polls++ > 100 )); do sleep 0.05; done
kill -INT $decide_pid
wait $decide_pid || interrupt_status=$?
assert_equal 130 "$interrupt_status"
! kill -0 "$(<"$tmp/slow.pid")" 2>/dev/null || fail 'interrupted decision left its adapter running'
