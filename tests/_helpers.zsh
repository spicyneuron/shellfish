# Shared unit-test setup. Sourced, never executed.

emulate -R zsh
setopt err_exit no_aliases no_multios pipe_fail

typeset -gr ROOT=${${(%):-%x}:A:h:h}
typeset -g SF_ROOT=$ROOT
typeset -gr SF_TEST_SESSIONS=$ROOT/tests/fixtures/session
typeset -gr SF_TEST_BACKEND=$ROOT/tests/fixtures/backend/run
typeset -g tmp=''
# EXIT traps inside functions fire on return; keep cleanup at source scope.
trap '[[ -z $tmp ]] || rm -rf -- "$tmp"' EXIT

sf_test_source() {
  local module
  for module in "$@"; do
    source "$ROOT/lib/$module"
  done
  setopt err_exit no_aliases no_multios pipe_fail
}

sf_test_tmp() {
  local name=${1:-unit}
  [[ -z $tmp ]] || rm -rf -- "$tmp"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-${name}-test.XXXXXX")
  # mktemp inherits TMPDIR's trailing slash; library code returns :a paths.
  tmp=${tmp:a}
}

# err_exit plus this trap turn every bare test expression into a located
# assertion: the trap names the statement, then err_exit abandons the file.
# funcfiletrace's outermost frame is the top-level line the reader cares about,
# even when the failure surfaced inside a library function.
typeset -ga sf_test_detail=()
TRAPZERR() {
  emulate -L zsh
  setopt extended_glob
  local frame=${funcfiletrace[-1]} source_file source_line statement=''
  local -a source_lines
  [[ -n $frame ]] || return 0
  source_file=${frame%:*}
  source_line=${frame##*:}
  # A compound statement reports the line it opened on, which may be a comment,
  # and a test that changed directory leaves a relative frame unreadable. Both
  # degrade to the bare location rather than quoting something misleading.
  if [[ -r $source_file ]]; then
    # Quoted so blank lines stay as empty fields and keep the index aligned.
    source_lines=( "${(@f)$(<$source_file)}" )
    statement=${source_lines[source_line]##[[:space:]]#}
    [[ $statement != \#* ]] || statement=''
  fi
  print -u2 -r -- "${source_file#$ROOT/tests/}:$source_line${statement:+: $statement}"
  (( ! ${#sf_test_detail} )) || print -u2 -rl -- ${(@)sf_test_detail/#/  }
  sf_test_detail=()
}

# Assertions describe the mismatch and return, leaving the trap to locate it.
assert_equal() {
  [[ $1 == $2 ]] || {
    sf_test_detail=( "expected ${(qqqq)1}" "     got ${(qqqq)2}" )
    return 1
  }
}

fail() {
  sf_test_detail=( "$@" )
  return 1
}

assert_session_unlocked() {
  local session=$1
  [[ -f ${session}.lock && ! -L ${session}.lock ]] &&
    zsh -fc 'zmodload zsh/system; zsystem flock -t 0 "$1"' -- "${session}.lock" 2>/dev/null ||
    fail "session lock is unavailable: $session"
}

# Frozen runtime used by tool and exec tests. Optional system-file path.
sf_test_runtime() {
  local system=${1-} tool=$ROOT/default/tools/shell content
  typeset -g SF_TEST_RUNTIME SF_TEST_SYSTEM_RECORD=''
  SF_TEST_RUNTIME=$(jq -cn \
    --arg command "$SF_TEST_BACKEND" \
    --arg system "$system" \
    --arg tool "$tool" \
    --arg fence "${commands[fence]:A}" \
    --slurpfile tool_manifest "$tool/tool.json" '
      {
        profile:{request:{model:"test-model"}},
        backend:{name:"test",command:$command,endpoint:"https://example.invalid/test",
          api_key_env:"",env_file:"",insecure_tls:false,http_timeout:30,http_stall:10},
        harness:{sandbox_read_paths:[],sandbox_write_paths:[],fence:$fence,
          tools:[{name:"shell",command:($tool+"/run"),
            settings:(if $tool_manifest[0].sandbox then {} else null end),
            manifest:$tool_manifest[0]}],sandbox:false,
          max_requests_per_turn:8,max_tool_calls_per_request:16,max_capture_bytes:65536}
      }
    ')
  if [[ -n $system ]]; then
    content=$(<"$system")
    SF_TEST_SYSTEM_RECORD=$(jq -cn --arg content "$content" \
      '{type:"system",content:$content}')
  fi
}

sf_test_session() {
  SF_SESSION_PATH=$1
  sf_session_prepare "$SF_TEST_RUNTIME" "$SF_TEST_SYSTEM_RECORD" && sf_session_create
}

sf_test_turn() {
  local prompt=$1 session=$2 permission_available=${3:-0} reply=${4-}
  { [[ -z $reply ]] || print -r -- "$reply" } |
    SF_ROOT=$ROOT SF_TEST_TURN_PROMPT=$prompt SF_TEST_TURN_SESSION=$session \
    SF_TEST_TURN_PERMISSION=$permission_available zsh -f -c '
  source "$SF_ROOT/lib/exec.zsh"
  typeset -g SF_API_KEY="" SF_API_KEY_SOURCE=""
  SF_EXEC[jsonl]=1
  message=$(jq -cn --arg text "$SF_TEST_TURN_PROMPT" \
    '\''{type:"message",role:"user",content:[{type:"text",text:$text}]}'\'') || exit
  sf_exec_turn "$message" "$SF_TEST_TURN_SESSION" \
    "$SF_TEST_TURN_PERMISSION" || true
'
}
