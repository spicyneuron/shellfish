#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp providers-openai-decisions
typeset decide="$ROOT/share/providers/openai_decisions/decide"
typeset req="$tmp/request.json"
typeset res="$tmp/output.json"

cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  case $1 in
    --data-binary) cp "${2#@}" "$PROVIDER_TEST_BODY" ; shift 2 ;;
    --header) [[ $2 == @* ]] && cp "${2#@}" "$PROVIDER_TEST_HEADERS" ; shift 2 ;;
    *) shift ;;
  esac
done
cat "$PROVIDER_TEST_RESPONSE"
printf %s "${PROVIDER_TEST_STATUS:-200}" >&2
EOF
chmod +x "$tmp/curl"
export PATH="$tmp:$PATH"
export PROVIDER_TEST_RESPONSE="$tmp/response"
export PROVIDER_TEST_BODY="$tmp/body"
export PROVIDER_TEST_HEADERS="$tmp/headers"

typeset decision='{
  "system":"Judge carefully.",
  "input":[{"type":"text","text":"A clip."},{"type":"json","data":{"frames":2}},
    {"type":"image","url":"data:image/png;base64,AAAA"}],
  "questions":{
    "moved":{"type":"predicate","instructions":"Did it move?",
      "criteria":{"true":"Any motion.","false":"No motion."}},
    "plain":{"type":"predicate","instructions":"Is it red?"},
    "direction":{"type":"choice","instructions":"Which way?",
      "choices":{"right":null,"left":"Leftward."}},
    "risk":{"type":"score","instructions":"How risky?","levels":["low","medium","high"]},
    "secret":{"type":"predicate","instructions":"Tell me."}}}'
jq -n --argjson decision "$decision" '$decision + {format_version:1,
  request:{model:"gpt-6-luna",prompt_cache_key:"k"},endpoint:"https://api.openai.test"}' >"$req"

cat >"$PROVIDER_TEST_RESPONSE" <<'EOF'
{"model":"gpt-6-luna","answers":[
  {"type":"predicate","name":"moved","probability":0.9},
  {"type":"predicate","name":"plain","probability":0.1},
  {"type":"choice","name":"direction","choice":"left","confidence":0.8,
    "probabilities":[{"value":"right","probability":0.2},{"value":"left","probability":0.8}]},
  {"type":"score","name":"risk","score":0.4,"confidence":0.7,
    "probabilities":[{"value":2,"label":"2","probability":0.05},
      {"value":0,"label":"0","probability":0.65},{"value":1,"label":"1","probability":0.3}]},
  {"type":"refusal","name":"secret"}],
 "usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":100,"cache_write_tokens":0},
   "output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":120}}
EOF

# Translate the request and normalize every answer type.
(builtin cd -- "$tmp" && OPENAI_API_KEY=test zsh -f "$decide" <"$req" >"$res")
jq -e '. == {
  model:"gpt-6-luna",prompt_cache_key:"k",
  input:[{type:"message",role:"developer",content:"Judge carefully."},
    {type:"message",role:"user",content:[{type:"input_text",text:"A clip."},
      {type:"input_json",data:{frames:2}},
      {type:"input_image",image_url:"data:image/png;base64,AAAA"}]}],
  questions:[
    {type:"predicate",name:"moved",
      instructions:"Did it move?\n\nAnswer true when: Any motion.\nAnswer false when: No motion."},
    {type:"predicate",name:"plain",instructions:"Is it red?"},
    {type:"choice",name:"direction",instructions:"Which way?",
      choices:[{value:"right"},{value:"left",description:"Leftward."}]},
    {type:"score",name:"risk",instructions:"How risky?",
      levels:[{label:"0",description:"low"},{label:"1",description:"medium"},
        {label:"2",description:"high"}]},
    {type:"predicate",name:"secret",instructions:"Tell me."}]}
' "$PROVIDER_TEST_BODY" >/dev/null || fail 'decisions sent the wrong body' "$(<"$PROVIDER_TEST_BODY")"
grep -Fxq 'Authorization: Bearer test' "$PROVIDER_TEST_HEADERS" ||
  fail 'decisions did not send the API key'
jq -e '. == {
  model:"gpt-6-luna",
  answers:{
    moved:{type:"predicate",probability:0.9},
    plain:{type:"predicate",probability:0.1},
    direction:{type:"choice",choice:"left",confidence:0.8,probabilities:{right:0.2,left:0.8}},
    risk:{type:"score",score:0.4,confidence:0.7,probabilities:[0.65,0.3,0.05]},
    secret:{type:"refusal"}},
  usage:{input_tokens:120,output_tokens:0,cached_tokens:100,reasoning_tokens:0}}
' "$res" >/dev/null || fail 'decisions normalized the wrong result' "$(<"$res")"

# Without a system message only the user message is sent.
jq '.system = ""' "$req" >"$tmp/no-system.json"
OPENAI_API_KEY=test zsh -f "$decide" <"$tmp/no-system.json" >/dev/null
jq -e '.input | length == 1 and .[0].role == "user"' "$PROVIDER_TEST_BODY" >/dev/null ||
  fail 'decisions sent an empty system message'

# Reject what the API cannot express or the provider owns.
jq '.input += [{type:"video",url:"data:video/mp4;base64,AAAA"}]' "$req" >"$tmp/video.json"
if OPENAI_API_KEY=test zsh -f "$decide" <"$tmp/video.json" >"$res" 2>"$tmp/error"; then
  fail 'decisions accepted video input'
fi
grep -Fq -- 'video input is not supported' "$tmp/error" || fail 'video rejection was unclear'
jq '.request.questions = []' "$req" >"$tmp/owned.json"
if OPENAI_API_KEY=test zsh -f "$decide" <"$tmp/owned.json" >"$res" 2>/dev/null; then
  fail 'decisions accepted a provider-owned request key'
fi

# Report HTTP errors.
print -r -- '{"error":{"message":"bad question"}}' >"$PROVIDER_TEST_RESPONSE"
if PROVIDER_TEST_STATUS=400 OPENAI_API_KEY=test zsh -f "$decide" <"$req" \
    >"$res" 2>"$tmp/error"; then
  fail 'decisions HTTP error was accepted'
fi
grep -Fq -- 'HTTP 400: bad question' "$tmp/error" || fail 'decisions HTTP error detail was lost'

# An error body is not a decision.
if OPENAI_API_KEY=test zsh -f "$decide" <"$req" >"$res" 2>"$tmp/error"; then
  fail 'decisions accepted an error body'
fi
grep -Fq -- 'cannot normalize API response' "$tmp/error" ||
  fail 'decisions error body was not reported'

# Run end to end through shellfish decide.
cat >"$PROVIDER_TEST_RESPONSE" <<'EOF'
{"model":"gpt-6-luna","answers":[{"type":"predicate","name":"moved","probability":0.9}],
 "usage":{"input_tokens":5,"output_tokens":0}}
EOF
typeset result
result=$(OPENAI_API_KEY=test zsh -f "$ROOT/bin/shellfish" decide \
  -m '{"provider":"openai_decisions","request":{"model":"gpt-6-luna"}}' \
  <<<'{"input":[{"type":"text","text":"x"}],
    "questions":{"moved":{"type":"predicate","instructions":"Did it move?"}}}') ||
  fail 'shellfish decide failed through openai_decisions'
jq -e '. == {model:"gpt-6-luna",answers:{moved:{type:"predicate",probability:0.9}},
  usage:{input_tokens:5,output_tokens:0}}' <<<"$result" >/dev/null ||
  fail 'shellfish decide returned the wrong result' "$result"

# oMLX receives system and JSON as user text, authorized by its own key.
typeset omlx="$ROOT/share/providers/openai_decisions_omlx/decide"
rm -f -- "$PROVIDER_TEST_HEADERS"
OPENAI_API_KEY=leaked OMLX_API_KEY=local zsh -f "$omlx" <"$req" >"$res"
jq -e '.input == [{type:"message",role:"user",content:[
    {type:"input_text",text:"Judge carefully."},{type:"input_text",text:"A clip."},
    {type:"input_text",text:"{\"frames\":2}"},
    {type:"input_image",image_url:"data:image/png;base64,AAAA"}]}]
' "$PROVIDER_TEST_BODY" >/dev/null || fail 'omlx sent the wrong body' "$(<"$PROVIDER_TEST_BODY")"
grep -Fxq 'Authorization: Bearer local' "$PROVIDER_TEST_HEADERS" ||
  fail 'omlx did not send its own key'
rm -f -- "$PROVIDER_TEST_HEADERS"
OPENAI_API_KEY=leaked zsh -f "$omlx" <"$req" >/dev/null
! grep -Fq leaked "$PROVIDER_TEST_HEADERS" 2>/dev/null || fail 'omlx sent the OpenAI key'
jq -e '.answers.moved == {type:"predicate",probability:0.9}' "$res" >/dev/null ||
  fail 'omlx normalized the wrong result' "$(<"$res")"
