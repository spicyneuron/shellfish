(( $+functions[sf_scratch_create] )) || source "${${(%):-%x}:A:h}/scratch.zsh"

typeset -g SF_BACKEND_NAME SF_BACKEND_TEMP_DIR SF_BACKEND_REQUEST_FILE
typeset -g SF_BACKEND_BODY_FILE SF_BACKEND_RESPONSE_FILE SF_BACKEND_STATUS_FILE
typeset -g SF_BACKEND_HEADERS_FILE SF_BACKEND_NORMALIZER_ERROR_FILE
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

sf_backend_credential() {
  local name=$1 value=$2
  [[ -n $value ]] || return 0
  [[ $value != *[[:cntrl:]]* ]] || sf_backend_die 'invalid authentication value'
  print -r -- "$name: $value" >>$SF_BACKEND_HEADERS_FILE
}

sf_backend_curl_args() {
  local endpoint=$1 insecure=$2 timeout=$3 stall=$4
  SF_BACKEND_CURL_ARGS=(--disable --silent --show-error --no-buffer --connect-timeout 15
    --max-time "$timeout" --speed-limit 1 --speed-time "$stall"
    --write-out '%{stderr}%{http_code}' --request POST --url "$endpoint"
    --header 'Content-Type: application/json' --data-binary "@$SF_BACKEND_BODY_FILE")
  [[ ! -s $SF_BACKEND_HEADERS_FILE ]] ||
    SF_BACKEND_CURL_ARGS+=(--header "@$SF_BACKEND_HEADERS_FILE")
  [[ $insecure != true ]] || SF_BACKEND_CURL_ARGS+=(--insecure)
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
