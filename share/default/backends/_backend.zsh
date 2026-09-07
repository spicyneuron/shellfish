(( $+functions[sf_scratch_create] )) || source "${${(%):-%x}:A:h:h:h:h}/lib/scratch.zsh"

typeset -g SF_BACKEND_NAME SF_BACKEND_TEMP_DIR SF_BACKEND_REQUEST_FILE
typeset -g SF_BACKEND_BODY_FILE SF_BACKEND_RESPONSE_FILE SF_BACKEND_STATUS_FILE
typeset -g SF_BACKEND_HEADERS_FILE SF_BACKEND_NORMALIZER_ERROR_FILE
# The request fields every adapter consumes, from sf_backend_request.
typeset -g SF_BACKEND_MODEL SF_BACKEND_ENDPOINT SF_BACKEND_INSECURE_TLS
typeset -g SF_BACKEND_HTTP_TIMEOUT SF_BACKEND_HTTP_STALL
typeset -ga SF_BACKEND_CURL_ARGS
typeset -gr SF_BACKEND_CONTROL_PATTERN='[\x{0000}-\x{001f}\x{007f}-\x{009f}]'

sf_backend_die() {
  print -u2 -r -- "$SF_BACKEND_NAME: $*"
  exit 1
}

sf_backend_setup() {
  SF_BACKEND_NAME=$1
  sf_scratch_create backends "$1" || sf_backend_die 'cannot create temporary directory'
  SF_BACKEND_TEMP_DIR=$REPLY
  SF_BACKEND_REQUEST_FILE=$SF_BACKEND_TEMP_DIR/request.json
  SF_BACKEND_BODY_FILE=$SF_BACKEND_TEMP_DIR/body.json
  SF_BACKEND_RESPONSE_FILE=$SF_BACKEND_TEMP_DIR/response
  SF_BACKEND_STATUS_FILE=$SF_BACKEND_TEMP_DIR/status
  SF_BACKEND_HEADERS_FILE=$SF_BACKEND_TEMP_DIR/headers
  SF_BACKEND_NORMALIZER_ERROR_FILE=$SF_BACKEND_TEMP_DIR/normalizer-error
  { : >$SF_BACKEND_HEADERS_FILE &&
    : >$SF_BACKEND_NORMALIZER_ERROR_FILE &&
    chmod 600 $SF_BACKEND_HEADERS_FILE } || {
    rm -rf -- $SF_BACKEND_TEMP_DIR
    sf_backend_die 'cannot prepare temporary files'
  }
}

# Reads the request fields an adapter consumes. The core validated the request
# before invoking the adapter, so this checks only what this program uses, plus
# the jq predicate an adapter passes for request options it cannot translate.
# The model check leads because jq's and short-circuits, so the predicate never
# runs against a missing options.request.
sf_backend_request() {
  local accepts=${1:-true}
  local -a fields
  fields=( "${(@f)$(jq -er "def accepted: $accepts;"'
    select((.options.request.model | type == "string" and . != "") and accepted) |
    .transport as $transport |
    select(($transport.endpoint | type == "string" and . != "") and
      ($transport.insecure_tls | type == "boolean") and
      ($transport.http_timeout | type == "number") and
      ($transport.http_stall | type == "number")) |
    .options.request.model, $transport.endpoint,
    ($transport.insecure_tls | tostring),
    ($transport.http_timeout | tostring), ($transport.http_stall | tostring)
  ' "$SF_BACKEND_REQUEST_FILE")}" ) || return 1
  (( ${#fields} == 5 )) || return 1
  SF_BACKEND_MODEL=$fields[1]
  SF_BACKEND_ENDPOINT=$fields[2]
  SF_BACKEND_INSECURE_TLS=$fields[3]
  SF_BACKEND_HTTP_TIMEOUT=$fields[4]
  SF_BACKEND_HTTP_STALL=$fields[5]
}

sf_backend_credential() {
  local name=$1 value=$2
  [[ -n $value ]] || return 0
  [[ $value != *[[:cntrl:]]* ]] || sf_backend_die 'invalid authentication value'
  print -r -- "$name: $value" >>$SF_BACKEND_HEADERS_FILE
}

sf_backend_curl_args() {
  SF_BACKEND_CURL_ARGS=(--disable --silent --show-error --no-buffer --connect-timeout 15
    --max-time "$SF_BACKEND_HTTP_TIMEOUT" --speed-limit 1 --speed-time "$SF_BACKEND_HTTP_STALL"
    --write-out '%{stderr}%{http_code}' --request POST --url "$SF_BACKEND_ENDPOINT"
    --header 'Content-Type: application/json' --data-binary "@$SF_BACKEND_BODY_FILE")
  [[ ! -s $SF_BACKEND_HEADERS_FILE ]] ||
    SF_BACKEND_CURL_ARGS+=(--header "@$SF_BACKEND_HEADERS_FILE")
  [[ $SF_BACKEND_INSECURE_TLS != true ]] || SF_BACKEND_CURL_ARGS+=(--insecure)
}

# Model metadata is a side lookup, so it uses the request's TLS setting but its
# own endpoint and tighter bounds.
sf_backend_context_curl_args() {
  local endpoint=$1 insecure=$SF_BACKEND_INSECURE_TLS
  integer timeout=$SF_BACKEND_HTTP_TIMEOUT stall=$SF_BACKEND_HTTP_STALL
  (( timeout <= 10 )) || timeout=10
  (( stall <= 5 )) || stall=5
  SF_BACKEND_CURL_ARGS=(--disable --silent --show-error --fail-with-body
    --connect-timeout 5 --max-time "$timeout" --speed-limit 1 --speed-time "$stall"
    --request GET --url "$endpoint")
  [[ ! -s $SF_BACKEND_HEADERS_FILE ]] ||
    SF_BACKEND_CURL_ARGS+=(--header "@$SF_BACKEND_HEADERS_FILE")
  [[ $insecure != true ]] || SF_BACKEND_CURL_ARGS+=(--insecure)
}

# Sends the prepared body and normalizes the response with the adapter's jq
# program, given last as jq takes it. The body streams to the normalizer rather
# than landing in a file first, so a response is normalized while it is still
# arriving. It is copied aside on the way past only so a failure has something to
# quote; nothing reads that copy when the exchange succeeds. With the body on
# stdout the status travels on stderr, written last, so the three characters it
# ends with are the code. The normalizer's stderr is captured so sf_backend_finish
# can report a concise protocol or normalization reason.
sf_backend_stream() {
  local -a statuses
  set +e
  curl "${SF_BACKEND_CURL_ARGS[@]}" 2>"$SF_BACKEND_STATUS_FILE" |
    tee "$SF_BACKEND_RESPONSE_FILE" |
    jq -nRrc --unbuffered "$@" 2>"$SF_BACKEND_NORMALIZER_ERROR_FILE"
  statuses=( $pipestatus )
  set -e
  sf_backend_finish "${statuses[@]}"
}

sf_backend_finish() {
  local -a statuses=( "$@" )
  local stage http_status message
  for stage in $statuses; do
    (( stage < 128 )) || exit $stage
  done
  if (( statuses[1] != 0 )); then
    case $statuses[1] in
      6) message='could not resolve the provider host' ;;
      7) message='could not connect to the provider' ;;
      28) message='request timed out' ;;
      35|51|52|56|60) message='TLS connection failed' ;;
      *) message='request failed' ;;
    esac
    sf_backend_die "$message (curl status $statuses[1])"
  fi
  http_status=$(<$SF_BACKEND_STATUS_FILE)
  http_status=${http_status[-3,-1]}
  [[ $http_status == <-> && ${#http_status} == 3 ]] ||
    sf_backend_die 'cannot read the response status'
  if [[ $http_status != 2* ]]; then
    message=$(jq -Rrsc '
      def safe: gsub("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]"; "�");
      . as $raw | ([splits("\\n") | sub("\\r$"; "") | select(startswith("data:")) |
        sub("^data:[ ]?"; "") | fromjson? | .error.message?] | first) as $stream |
      (($raw | fromjson? | .error.message?) // $stream // "") |
      if type == "string" then safe else "" end
    ' <$SF_BACKEND_RESPONSE_FILE 2>/dev/null) || message=''
    if [[ $http_status == 401 || $http_status == 403 ]]; then
      if [[ -s $SF_BACKEND_HEADERS_FILE ]]; then
        sf_backend_die "credentials rejected (HTTP $http_status)${SHELLFISH_API_KEY_SOURCE:+ for $SHELLFISH_API_KEY_SOURCE}${message:+: $message}"
      fi
      sf_backend_die "credentials rejected (HTTP $http_status); no API key was supplied${SHELLFISH_API_KEY_SOURCE:+ (set $SHELLFISH_API_KEY_SOURCE)}${message:+: $message}"
    fi
    sf_backend_die "HTTP $http_status${message:+: $message}"
  elif (( statuses[3] != 0 )); then
    message=$(LC_ALL=C tr -s '[:cntrl:]' ' ' <$SF_BACKEND_NORMALIZER_ERROR_FILE)
    sf_backend_die "cannot normalize API response${message:+: ${message[1,1000]}}"
  fi
}
