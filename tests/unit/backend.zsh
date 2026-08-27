#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_source backend.zsh
sf_test_tmp backend

# Setup creates files with restrictive permissions.
sf_backend_setup test_backend
assert_equal 600 "$(stat -f %Lp "$SF_BACKEND_HEADERS_FILE")"

# Empty credential is a no-op.
sf_backend_credential Authorization ''
[[ ! -s $SF_BACKEND_HEADERS_FILE ]]

# Valid credential appends header.
sf_backend_credential Authorization 'Bearer secret-token'
assert_equal 'Authorization: Bearer secret-token' "$(<"$SF_BACKEND_HEADERS_FILE")"

# Control characters in credentials are rejected.
(
  sf_backend_credential Authorization $'Bearer bad\nnewline'
) 2>"$tmp/cred-err" || true
[[ "$(<"$tmp/cred-err")" == *"invalid authentication value"* ]]

# Curl arguments construction includes headers, timeouts, and insecure flags.
sf_backend_curl_args 'https://api.example.com/v1' true 60 10
[[ "${SF_BACKEND_CURL_ARGS[*]}" == *'--url https://api.example.com/v1'* ]]
[[ "${SF_BACKEND_CURL_ARGS[*]}" == *"--max-time 60"* ]]
[[ "${SF_BACKEND_CURL_ARGS[*]}" == *"--speed-time 10"* ]]
[[ "${SF_BACKEND_CURL_ARGS[*]}" == *"--header @$SF_BACKEND_HEADERS_FILE"* ]]
[[ "${SF_BACKEND_CURL_ARGS[*]}" == *"--insecure"* ]]

# Curl connection and resolution failures report dedicated messages.
for code expected in \
    6 'could not resolve the provider host' \
    7 'could not connect to the provider' \
    28 'request timed out' \
    35 'TLS connection failed'; do
  (
    sf_backend_finish "$code" 0 0
  ) 2>"$tmp/curl-err" || true
  [[ "$(<"$tmp/curl-err")" == *"$expected (curl status $code)"* ]]
done

# A success status finishes without reporting an error.
print -r -- '200' >"$SF_BACKEND_STATUS_FILE"
print -r -- '{"error":{"message":"overloaded"}}' >"$SF_BACKEND_RESPONSE_FILE"
sf_backend_finish 0 0 0

# HTTP 401 with headers reports credential rejection.
print -r -- '401' >"$SF_BACKEND_STATUS_FILE"
print -r -- '{"error":{"message":"invalid api key"}}' >"$SF_BACKEND_RESPONSE_FILE"
(
  sf_backend_finish 0 0 0
) 2>"$tmp/http-err" || true
[[ "$(<"$tmp/http-err")" == *"credentials rejected (HTTP 401): invalid api key"* ]]

# HTTP 401 without headers reports missing API key.
: >"$SF_BACKEND_HEADERS_FILE"
(
  sf_backend_finish 0 0 0
) 2>"$tmp/http-no-key" || true
[[ "$(<"$tmp/http-no-key")" == *"no API key was supplied"* ]]

# HTTP 500 reports error status and message.
print -r -- '500' >"$SF_BACKEND_STATUS_FILE"
print -r -- '{"error":{"message":"internal error"}}' >"$SF_BACKEND_RESPONSE_FILE"
(
  sf_backend_finish 0 0 0
) 2>"$tmp/http-500" || true
[[ "$(<"$tmp/http-500")" == *"HTTP 500: internal error"* ]]

# Normalizer failure reports normalizer error output.
print -r -- '200' >"$SF_BACKEND_STATUS_FILE"
print -r -- 'malformed stream chunk' >"$SF_BACKEND_NORMALIZER_ERROR_FILE"
(
  sf_backend_finish 0 0 1
) 2>"$tmp/norm-err" || true
[[ "$(<"$tmp/norm-err")" == *"cannot normalize API response: malformed stream chunk"* ]]

rm -rf -- "$SF_BACKEND_TEMP_DIR"
