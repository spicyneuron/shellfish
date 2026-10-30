#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source share/providers/_provider.zsh
sf_test_tmp providers

# Create private provider files.
sf_provider_setup test_provider
[[ $SF_PROVIDER_TEMP_DIR == */shellfish-provider-test_provider.* ]]
assert_equal 700 "$(stat -f %Lp "$SF_PROVIDER_TEMP_DIR")"
assert_equal 600 "$(stat -f %Lp "$SF_PROVIDER_HEADERS_FILE")"

# Ignore empty credentials.
sf_provider_credential Authorization ''
[[ ! -s $SF_PROVIDER_HEADERS_FILE ]]

# Append valid credentials.
sf_provider_credential Authorization 'Bearer secret-token'
assert_equal 'Authorization: Bearer secret-token' "$(<"$SF_PROVIDER_HEADERS_FILE")"

# Reject credential control characters.
integer operation_status=0
(
  sf_provider_credential Authorization $'Bearer bad\nnewline'
) 2>"$tmp/cred-err" || operation_status=$?
(( operation_status != 0 )) || fail 'invalid authentication value was accepted'
[[ "$(<"$tmp/cred-err")" == *"invalid authentication value"* ]]

# Omitted transport settings use secure defaults.
cat >"$SF_PROVIDER_REQUEST_FILE" <<'JSON'
{"request":{"model":"test-model"},"endpoint":"https://api.example.com/v1"}
JSON
sf_provider_request
assert_equal 3600 "$SF_PROVIDER_HTTP_TIMEOUT"
assert_equal 300 "$SF_PROVIDER_HTTP_STALL"
assert_equal 0 "$SF_PROVIDER_INSECURE_TLS"
sf_provider_curl_args
[[ ${SF_PROVIDER_CURL_ARGS[(Ie)--insecure]} == 0 ]]

# Supplied transport settings remain separate from provider parameters.
jq '.config={http_timeout:60,http_stall:10,insecure_tls:true}' \
  "$SF_PROVIDER_REQUEST_FILE" >"$tmp/configured.json"
cp "$tmp/configured.json" "$SF_PROVIDER_REQUEST_FILE"
sf_provider_request
assert_equal test-model "$SF_PROVIDER_MODEL"
assert_equal https://api.example.com/v1 "$SF_PROVIDER_ENDPOINT"

# Reject unsupported request options.
operation_status=0
sf_provider_request '.request | has("model") | not' || operation_status=$?
(( operation_status != 0 )) || fail 'untranslatable request options were accepted'

# Require a model.
print -r -- '{"endpoint":"https://api.example.com/v1"}' >"$SF_PROVIDER_REQUEST_FILE"
operation_status=0
sf_provider_request '.request | has("stream_options") | not' || operation_status=$?
(( operation_status != 0 )) || fail 'request without a model was accepted'

# Apply transport settings.
sf_provider_curl_args
[[ "${SF_PROVIDER_CURL_ARGS[*]}" == *'--url https://api.example.com/v1'* ]]
[[ "${SF_PROVIDER_CURL_ARGS[*]}" == *'--max-time 60'* ]]
[[ "${SF_PROVIDER_CURL_ARGS[*]}" == *'--speed-time 10'* ]]
[[ "${SF_PROVIDER_CURL_ARGS[*]}" == *'--insecure'* ]]

for config in null false 1 '[]' '"text"' '{"unknown":1}' '{"http_timeout":null}' \
    '{"http_timeout":0}' '{"http_timeout":-1}' '{"http_timeout":1.5}' \
    '{"http_timeout":"60"}' '{"http_stall":false}' '{"http_stall":0}' \
    '{"insecure_tls":null}' '{"insecure_tls":1}' '{"insecure_tls":"false"}'; do
  jq --argjson config "$config" '.config=$config' "$tmp/configured.json" \
    >"$SF_PROVIDER_REQUEST_FILE"
  if (sf_provider_request) 2>"$tmp/config-err"; then
    fail "invalid provider config was accepted: $config"
  fi
  grep -q '^test_provider: config' "$tmp/config-err"
done

# Report curl transport failures.
print -rn -- 000 >"$SF_PROVIDER_STATUS_FILE"
operation_status=0
(
  sf_provider_finish '.error.message?' 28 0 0
) 2>"$tmp/curl-err" || operation_status=$?
(( operation_status != 0 )) || fail 'curl timeout was accepted'
[[ "$(<"$tmp/curl-err")" == *'request timed out (curl status 28)'* ]]

# Accept successful HTTP responses.
print -r -- '200' >"$SF_PROVIDER_STATUS_FILE"
print -r -- '{"error":{"message":"overloaded"}}' >"$SF_PROVIDER_RESPONSE_FILE"
sf_provider_finish '.error.message?' 0 0 0

# Report rejected credentials.
print -r -- '401' >"$SF_PROVIDER_STATUS_FILE"
print -r -- '{"error":{"message":"invalid api key"}}' >"$SF_PROVIDER_RESPONSE_FILE"
operation_status=0
(
  sf_provider_finish '.error.message?' 0 0 0
) 2>"$tmp/http-err" || operation_status=$?
(( operation_status != 0 )) || fail 'HTTP 401 with credentials was accepted'
[[ "$(<"$tmp/http-err")" == *"credentials rejected (HTTP 401): invalid api key"* ]]

# Report missing credentials.
: >"$SF_PROVIDER_HEADERS_FILE"
operation_status=0
(
  sf_provider_finish '.error.message?' 0 0 0
) 2>"$tmp/http-no-key" || operation_status=$?
(( operation_status != 0 )) || fail 'HTTP 401 without credentials was accepted'
[[ "$(<"$tmp/http-no-key")" == *"no API key was supplied"* ]]

# Report HTTP errors.
print -r -- '500' >"$SF_PROVIDER_STATUS_FILE"
print -r -- '{"error":{"message":"internal error"}}' >"$SF_PROVIDER_RESPONSE_FILE"
operation_status=0
(
  sf_provider_finish '.error.message?' 0 0 0
) 2>"$tmp/http-500" || operation_status=$?
(( operation_status != 0 )) || fail 'HTTP 500 was accepted'
[[ "$(<"$tmp/http-500")" == *"HTTP 500: internal error"* ]]

# Apply the provider's error selector.
print -r -- '400' >"$SF_PROVIDER_STATUS_FILE"
print -r -- '{"detail":"unsupported parameter"}' >"$SF_PROVIDER_RESPONSE_FILE"
operation_status=0
(
  sf_provider_finish '.detail?' 0 0 0
) 2>"$tmp/http-400" || operation_status=$?
(( operation_status != 0 )) || fail 'HTTP 400 was accepted'
[[ "$(<"$tmp/http-400")" == *"HTTP 400: unsupported parameter"* ]]

# Report normalizer failures.
print -r -- '200' >"$SF_PROVIDER_STATUS_FILE"
print -r -- 'malformed stream chunk' >"$SF_PROVIDER_NORMALIZER_ERROR_FILE"
operation_status=0
(
  sf_provider_finish '.error.message?' 0 0 1
) 2>"$tmp/norm-err" || operation_status=$?
(( operation_status != 0 )) || fail 'normalizer failure was accepted'
[[ "$(<"$tmp/norm-err")" == *"cannot normalize API response: malformed stream chunk"* ]]

rm -rf -- "$SF_PROVIDER_TEMP_DIR"
