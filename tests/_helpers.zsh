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
  export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
}

# An isolated config directory, then one profile folder inside it.
sf_test_config() {
  typeset -g SF_TEST_CONFIG="$tmp/config/shellfish"
  mkdir -p "$SF_TEST_CONFIG/profiles"
}

sf_test_profile() {
  mkdir -p "$SF_TEST_CONFIG/profiles/$1"
  print -r -- "$2" >"$SF_TEST_CONFIG/profiles/$1/profile.jsonc"
}

# err_exit plus this trap turn every bare test expression into a located
# assertion; the trap names the statement, then err_exit abandons the file.
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
  # and a test that changed directory leaves a relative frame unreadable; both
  # degrade to the bare location.
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
    include "lib/runtime";
    include "lib/session";
    (.[0] | canonical_session_header) and
    (.[1:] | session_state | true) and
    ($stop == "" or .[-1].stop == $stop)
  ' "$session" >/dev/null || {
    sf_test_detail=( "not a canonical session${stop:+ ending in stop \"$stop\"}: $session" )
    return 1
  }
}

# Frozen runtime used by tool and exec tests. Optional system-file path.
sf_test_runtime() {
  local system=${1-} tool=$ROOT/share/profiles/default/tools/shell
  typeset -g SF_TEST_RUNTIME SF_TEST_SYSTEM=''
  [[ -z $system ]] || SF_TEST_SYSTEM=$(<"$system")
  SF_TEST_RUNTIME=$(jq -cn \
    --arg command "$SF_TEST_BACKEND" \
    --arg tool "$tool" \
    --slurpfile tool_manifest "$tool/manifest.json" '
      {
        request:{model:"test-model"},
        system:[],
        backend:{command:$command,endpoint:"https://example.invalid/test",
          insecure_tls:false,http_timeout:30,http_stall:10},
        harness:{sandbox_read_paths:[],sandbox_write_paths:[],
          tools:[{name:"shell",command:($tool+"/run"),
            settings:(if $tool_manifest[0].sandbox then ($tool+"/fence.jsonc") else null end),
            manifest:$tool_manifest[0]}],sandbox:false,
          max_requests_per_turn:8,max_tool_calls_per_request:16,max_capture_bytes:65536}
      }
    ')
}

sf_test_session() {
  local session=$1 cwd created header
  cwd=$(pwd -P)
  created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  header=$(jq -cn --arg cwd "$cwd" --arg created "$created" \
    --argjson runtime "$SF_TEST_RUNTIME" \
    '{type:"session",format_version:1,cwd:$cwd,created:$created,runtime:$runtime}')
  (umask 077; print -r -- "$header" >"$session")
  [[ -z $SF_TEST_SYSTEM ]] || jq -cn --arg content "$SF_TEST_SYSTEM" \
    '{type:"system",content:$content}' >>"$session"
}

sf_test_run() {
  local prompt=$1 session=$2 reply=${3-}
  {
    jq -cn --arg text "$prompt" '{type:"user",content:[{type:"text",text:$text}]}'
    [[ -z $reply ]] || print -r -- "$reply"
  } | "$ROOT/bin/shellfish" run --jsonl --session "$session"
}
