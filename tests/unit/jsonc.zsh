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
