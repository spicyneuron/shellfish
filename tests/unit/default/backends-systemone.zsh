#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp backends-systemone
typeset decide="$ROOT/share/backends/systemone/decide"
typeset omlx="$ROOT/share/backends/systemone-omlx/decide"
typeset req="$tmp/request.json"
typeset res="$tmp/output.json"

cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
: >"$BACKEND_TEST_HEADERS"
while (($#)); do
  case $1 in
    --data-binary) cp "${2#@}" "$BACKEND_TEST_BODY" ; shift 2 ;;
    --header)
      if [[ $2 == @* ]]; then cat "${2#@}"; else printf '%s\n' "$2"; fi >>"$BACKEND_TEST_HEADERS"
      shift 2 ;;
    *) shift ;;
  esac
done
cat "$BACKEND_TEST_RESPONSE"
printf %s "${BACKEND_TEST_STATUS:-200}" >&2
EOF
chmod +x "$tmp/curl"
export PATH="$tmp:$PATH"
export BACKEND_TEST_RESPONSE="$tmp/response"
export BACKEND_TEST_BODY="$tmp/body"
export BACKEND_TEST_HEADERS="$tmp/headers"

typeset decision='{
  "system":"Judge carefully.",
  "input":[{"type":"text","text":"A clip."},{"type":"json","data":{"frames":2}},
    {"type":"image","url":"data:image/png;base64,AAAA"},
    {"type":"image","url":"data:image/jpeg;base64,BBBB"}],
  "questions":{
    "moved":{"type":"predicate","instructions":"Did it move?",
      "criteria":{"true":"Any motion.","false":"No motion."}},
    "plain":{"type":"predicate","instructions":"Is it red?"},
    "direction":{"type":"choice","instructions":"Which way?",
      "choices":{"right":null,"left":"Leftward."}},
    "risk":{"type":"score","instructions":"How risky?","levels":["low","medium","high"]}}}'
jq -n --argjson decision "$decision" '$decision + {format_version:1,
  request:{model:"jev-latest"},endpoint:"https://api.typesafe.test"}' >"$req"

cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"model":"jev-1.14.0","answers":{
  "moved":{"type":"noul","noul":0.9},
  "plain":{"type":"noul","noul":0.1},
  "direction":{"type":"choice","choice":"left","confidence":0.8,
    "probabilities":{"right":0.2,"left":0.8}},
  "risk":{"type":"score","score":0.4,"confidence":0.7,
    "legend":{"0":"low","1":"medium","2":"high"},
    "probabilities":{"2":0.05,"0":0.65,"1":0.3}}},
 "usage":{"input_tokens":120,"output_tokens":0}}
EOF

# Translate the request and normalize every answer type.
(builtin cd -- "$tmp" && TYPESAFE_API_KEY=test zsh -f "$decide" <"$req" >"$res")
jq -e '
  .state[3] as $png | .state[4] as $jpeg |
  ($png | test("^<image-[0-9a-f]{16}-1>$")) and ($jpeg | test("^<image-[0-9a-f]{16}-2>$")) and
  del(.state, .assets) == {
    model:"jev-latest",
    questions:{
      moved:{type:"noul",instructions:"Did it move?",
        criteria:{true:"Any motion.",false:"No motion."}},
      plain:{type:"noul",instructions:"Is it red?"},
      direction:{type:"choice",instructions:"Which way?",
        criteria:{right:null,left:"Leftward."}},
      risk:{type:"score",instructions:"How risky?",criteria:["low","medium","high"]}}} and
  .state[:3] == [{system:"Judge carefully."},"A clip.",{frames:2}] and
  .assets == {($png):{type:"image",format:"png",data_base64:"AAAA"},
    ($jpeg):{type:"image",format:"jpeg",data_base64:"BBBB"}}
' "$BACKEND_TEST_BODY" >/dev/null || fail 'systemone sent the wrong body' "$(<"$BACKEND_TEST_BODY")"
grep -Fxq 'Authorization: Bearer test' "$BACKEND_TEST_HEADERS" ||
  fail 'systemone did not send the API key'
grep -Fxq 'TypeSafe-Danger-Zone-Images: true' "$BACKEND_TEST_HEADERS" ||
  fail 'systemone did not enable images'
jq -e '. == {
  model:"jev-1.14.0",
  answers:{
    moved:{type:"predicate",probability:0.9},
    plain:{type:"predicate",probability:0.1},
    direction:{type:"choice",choice:"left",confidence:0.8,probabilities:{right:0.2,left:0.8}},
    risk:{type:"score",score:0.4,confidence:0.7,probabilities:[0.65,0.3,0.05]}},
  usage:{input_tokens:120,output_tokens:0}}
' "$res" >/dev/null || fail 'systemone normalized the wrong result' "$(<"$res")"

# Text alone sends no system, assets, or image header.
jq '.system = "" | .input |= map(select(.type == "text"))' "$req" >"$tmp/text.json"
zsh -f "$decide" <"$tmp/text.json" >/dev/null
jq -e '.state == ["A clip."] and (has("assets") | not)' "$BACKEND_TEST_BODY" >/dev/null ||
  fail 'systemone sent media fields for text' "$(<"$BACKEND_TEST_BODY")"
! grep -Fq 'TypeSafe-Danger-Zone-Images' "$BACKEND_TEST_HEADERS" ||
  fail 'systemone enabled images without any'

# Reject what the API cannot express or the adapter owns.
jq '.input += [{type:"video",url:"data:video/mp4;base64,AAAA"}]' "$req" >"$tmp/video.json"
if zsh -f "$decide" <"$tmp/video.json" >"$res" 2>"$tmp/error"; then
  fail 'systemone accepted video input'
fi
grep -Fq -- 'video input is not supported' "$tmp/error" || fail 'video rejection was unclear'
jq '.input = [{type:"image",url:"https://example.test/a.png"}]' "$req" >"$tmp/remote.json"
if zsh -f "$decide" <"$tmp/remote.json" >"$res" 2>"$tmp/error"; then
  fail 'systemone accepted a remote image'
fi
grep -Fq -- 'images must be PNG or JPEG data URIs' "$tmp/error" ||
  fail 'image rejection was unclear'
jq '.request.state = "x"' "$req" >"$tmp/owned.json"
if zsh -f "$decide" <"$tmp/owned.json" >"$res" 2>/dev/null; then
  fail 'systemone accepted an adapter-owned request key'
fi

# Report validation errors.
print -r -- '{"detail":[{"loc":["body","questions"],"msg":"Field required","type":"missing"}]}' \
  >"$BACKEND_TEST_RESPONSE.error"
cp "$BACKEND_TEST_RESPONSE" "$BACKEND_TEST_RESPONSE.ok"
cp "$BACKEND_TEST_RESPONSE.error" "$BACKEND_TEST_RESPONSE"
if BACKEND_TEST_STATUS=422 zsh -f "$decide" <"$req" >"$res" 2>"$tmp/error"; then
  fail 'systemone HTTP error was accepted'
fi
grep -Fq -- 'HTTP 422: Field required' "$tmp/error" || fail 'systemone 422 detail was lost'
print -r -- '{"detail":"Unknown model"}' >"$BACKEND_TEST_RESPONSE"
if BACKEND_TEST_STATUS=400 zsh -f "$decide" <"$req" >"$res" 2>"$tmp/error"; then
  fail 'systemone HTTP error was accepted'
fi
grep -Fq -- 'HTTP 400: Unknown model' "$tmp/error" || fail 'systemone 400 detail was lost'
print -r -- '{"error":{"message":"Model not found","type":"not_found_error"}}' \
  >"$BACKEND_TEST_RESPONSE"
if BACKEND_TEST_STATUS=404 zsh -f "$decide" <"$req" >"$res" 2>"$tmp/error"; then
  fail 'systemone HTTP error was accepted'
fi
grep -Fq -- 'HTTP 404: Model not found' "$tmp/error" || fail 'oMLX error message was lost'
cp "$BACKEND_TEST_RESPONSE.ok" "$BACKEND_TEST_RESPONSE"

# oMLX takes media as top-level lists instead of placed assets.
jq '.input += [{type:"video",url:"data:video/mp4;base64,CCCC"}]' "$req" >"$tmp/omlx.json"
TYPESAFE_API_KEY=leaked OMLX_API_KEY=local zsh -f "$omlx" <"$tmp/omlx.json" >"$res"
grep -Fxq 'Authorization: Bearer local' "$BACKEND_TEST_HEADERS" && ! grep -Fq leaked "$BACKEND_TEST_HEADERS" ||
  fail 'omlx did not send only its own key'
jq -e '
  .images == ["data:image/png;base64,AAAA","data:image/jpeg;base64,BBBB"] and
  .videos == ["data:video/mp4;base64,CCCC"] and
  .state == [{system:"Judge carefully."},"A clip.",{frames:2}] and (has("assets") | not)
' "$BACKEND_TEST_BODY" >/dev/null || fail 'omlx sent the wrong body' "$(<"$BACKEND_TEST_BODY")"
! grep -Fq 'TypeSafe-Danger-Zone-Images' "$BACKEND_TEST_HEADERS" ||
  fail 'omlx enabled placed images'
jq -e '.answers.moved == {type:"predicate",probability:0.9}' "$res" >/dev/null ||
  fail 'omlx normalized the wrong result' "$(<"$res")"

# Run end to end through shellfish decide.
typeset result question='{"input":[{"type":"text","text":"x"}],
  "questions":{"moved":{"type":"predicate","instructions":"Did it move?"}}}'
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"model":"jev-1.14.0","answers":{"moved":{"type":"noul","noul":0.9}},
 "usage":{"input_tokens":5,"output_tokens":0}}
EOF
result=$(TYPESAFE_API_KEY=test zsh -f "$ROOT/bin/shellfish" decide \
  -m '{"adapter":"systemone","request":{"model":"jev-latest"}}' <<<"$question") ||
  fail 'shellfish decide failed through systemone'
jq -e '. == {model:"jev-1.14.0",answers:{moved:{type:"predicate",probability:0.9}},
  usage:{input_tokens:5,output_tokens:0}}' <<<"$result" >/dev/null ||
  fail 'shellfish decide returned the wrong systemone result' "$result"
result=$(zsh -f "$ROOT/bin/shellfish" decide -m '{"adapter":"systemone-omlx",
  "endpoint":"http://127.0.0.1:8000/v1/systemone","request":{"model":"d3-flash"}}' \
  <<<"$question") || fail 'shellfish decide failed through systemone-omlx'
jq -e '.answers.moved == {type:"predicate",probability:0.9}' <<<"$result" >/dev/null ||
  fail 'shellfish decide returned the wrong omlx result' "$result"
