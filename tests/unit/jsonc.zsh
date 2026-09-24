#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_source lib/jsonc.zsh

typeset jsonc failure
sf_test_tmp jsonc

# Comment-like text inside strings survives.
cat >"$tmp/string-values.jsonc" <<'JSON'
{
  // line comment
  "line": "https://example.invalid/a//b",
  /* block comment */
  "block": "literal /* comment */",
  "quote": "escaped quote: \"// still text\" and \"/* too */\"",
  // another comment
  "path": "C:\\Users\\shellfish\\shellfish.jsonc"
}
JSON
jsonc=$(sf_jsonc_read "$tmp/string-values.jsonc")
jq -e '. == {
  line:"https://example.invalid/a//b",
  block:"literal /* comment */",
  quote:"escaped quote: \"// still text\" and \"/* too */\"",
  path:"C:\\Users\\shellfish\\shellfish.jsonc"
}' <<<"$jsonc" >/dev/null

# Trailing commas are removed across whitespace and comments, while strings
# and commas between values stay unchanged.
cat >"$tmp/trailing.jsonc" <<'JSON'
{
  "text": "comma, } ]",
  "items": [1, 2, // line comment
    ],
  "nested": {"value": 3, /* block comment */ },
}
JSON
jsonc=$(sf_jsonc_read "$tmp/trailing.jsonc")
jq -e '. == {text:"comma, } ]",items:[1,2],nested:{value:3}}' <<<"$jsonc" >/dev/null
jsonc=$(sf_jsonc_read_keyed "$tmp/trailing.jsonc" "$tmp/string-values.jsonc")
jq -e --arg first "$tmp/trailing.jsonc" --arg second "$tmp/string-values.jsonc" '
  .[$first].items == [1,2] and .[$second].line == "https://example.invalid/a//b"
' <<<"$jsonc" >/dev/null
for invalid in '[1,,2]' '[,]' '{,}'; do
  print -r -- "$invalid" >"$tmp/invalid-comma.jsonc"
  sf_jsonc_read "$tmp/invalid-comma.jsonc" >/dev/null 2>&1 &&
    fail "invalid comma was accepted: $invalid"
done

# Stripping comments keeps every line, so jq still locates a syntax error where
# the author wrote it.
cat >"$tmp/unbalanced.jsonc" <<'JSON'
{
  // line comment
  /* block
     comment */
  "open": [1, 2
}
JSON
failure=$(sf_jsonc_read "$tmp/unbalanced.jsonc" 2>&1) && fail 'invalid JSONC was accepted'
[[ $failure == *'line 6'* ]]
