# Shared unit-test setup. Sourced, never executed.

emulate -R zsh
setopt err_exit no_aliases no_bg_nice no_multios pipe_fail

typeset -gr ROOT=${${(%):-%x}:A:h:h}
typeset -g SF_ROOT=$ROOT
typeset -g SF_SHARE=$ROOT/share
typeset -gr SF_TEST_SESSIONS=$ROOT/tests/fixtures/session
typeset -gr SF_TEST_BACKEND=$ROOT/tests/fixtures/backend/run
typeset -g tmp=''
# EXIT traps inside functions fire on return; keep cleanup at source scope.
trap '[[ -z $tmp ]] || rm -rf -- "$tmp"' EXIT

sf_test_source() {
  local module
  for module in "$@"; do
    source "$ROOT/$module"
  done
  setopt err_exit no_aliases no_bg_nice no_multios pipe_fail
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

# The optional stop reason must match the final record.
assert_canonical_session() {
  local session=$1 stop=${2-}
  jq -L "$ROOT" -e -s --arg stop "$stop" '
    include "lib/runtime/schema";
    (.[0] | canonical_session_header(1)) and
    (.[1:] | canonical_session_records) and
    ($stop == "" or .[-1].stop == $stop)
  ' "$session" >/dev/null || {
    sf_test_detail=( "not a canonical session${stop:+ ending in stop \"$stop\"}: $session" )
    return 1
  }
}

# Frozen runtime used by tool and exec tests. Optional system-file path.
sf_test_runtime() {
  local system=${1-} tool=$ROOT/share/default/tools/shell
  typeset -g SF_TEST_RUNTIME
  SF_TEST_RUNTIME=$(jq -cn \
    --arg command "$SF_TEST_BACKEND" \
    --arg system "$system" \
    --arg tool "$tool" \
    --arg fence "${commands[fence]:A}" \
    --slurpfile tool_manifest "$tool/tool.json" '
      {
        profile:{request:{model:"test-model"},
          system:(if $system == "" then [] else [$system] end)},
        backend:{name:"test",command:$command,endpoint:"https://example.invalid/test",
          api_key_env:"",env_file:"",insecure_tls:false,http_timeout:30,http_stall:10},
        harness:{sandbox_read_paths:[],sandbox_write_paths:[],fence:$fence,
          tools:[{name:"shell",command:($tool+"/run"),
            settings:(if $tool_manifest[0].sandbox then ($tool+"/fence.jsonc") else null end),
            manifest:$tool_manifest[0]}],sandbox:false,
          max_requests_per_turn:8,max_tool_calls_per_request:16,max_capture_bytes:65536}
      }
    ')
}

sf_test_session() {
  SF_SESSION_PATH=$1
  SHELLFISH_SESSION_STATE=''
  sf_hooks_session_state_create && sf_session_prepare "$SF_TEST_RUNTIME" &&
    sf_session_system && sf_session_create
}

sf_test_turn() {
  local prompt=$1 session=$2 permission_available=${3:-0} reply=${4-}
  { [[ -z $reply ]] || print -r -- "$reply" } |
    SF_ROOT=$ROOT SF_TEST_TURN_PROMPT=$prompt SF_TEST_TURN_SESSION=$session \
    SF_TEST_TURN_PERMISSION=$permission_available zsh -f -c '
  source "$SF_ROOT/libexec/run/turn.zsh"
  typeset -g SF_API_KEY="" SF_API_KEY_SOURCE=""
  SF_RUN[jsonl]=1
  message=$(jq -cn --arg text "$SF_TEST_TURN_PROMPT" \
    '\''{type:"message",role:"user",content:[{type:"text",text:$text}]}'\'') || exit
  sf_run_turn "$message" "$SF_TEST_TURN_SESSION" \
    "$SF_TEST_TURN_PERMISSION" "$SF_TEST_TURN_PROMPT" || true
'
}
