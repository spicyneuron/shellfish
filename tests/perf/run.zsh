#!/usr/bin/env zsh

emulate -R zsh
setopt err_exit no_aliases no_multios pipe_fail
zmodload zsh/datetime

typeset -gr root=${0:A:h:h:h}
typeset iteration_arg=${1:-5}
(( $# <= 1 )) && [[ $iteration_arg == <1-> ]] || {
  print -u2 -r -- "Usage: $0 [positive-iterations]"
  exit 2
}
integer iterations=$iteration_arg
(( $+commands[jq] )) || { print -u2 -r -- 'tests/perf/run.zsh requires jq'; exit 2; }

typeset tmp
tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellfish-perf.XXXXXX")
trap 'if [[ -n ${SHELLFISH_PERF_KEEP-} ]]; then print -u2 -r -- "kept: $tmp"; else rm -rf -- "$tmp"; fi' EXIT
mkdir -p "$tmp/project" "$tmp/bin" "$tmp/shellfish/profiles" "$tmp/shellfish/models" \
  "$tmp/shellfish/providers/perf" "$tmp/shellfish/tools/perf"

cat >"$tmp/bin/jq" <<'EOF'
#!/bin/sh
printf '%s\n' "$SHELLFISH_PERF_RUN" >>"$SHELLFISH_PERF_JQ_LOG"
exec "$SHELLFISH_PERF_JQ" "$@"
EOF
cat >"$tmp/shellfish/providers/perf/manifest.json" <<'EOF'
{"endpoint":"https://example.invalid/perf"}
EOF
cat >"$tmp/shellfish/providers/perf/run" <<'EOF'
#!/usr/bin/env zsh
request=$(cat)
if "$SHELLFISH_PERF_JQ" -e '.messages[-1].type == "tool_result"' <<<"$request" >/dev/null; then
  response=$'{"type":"_assistant_message_delta","text":"ok"}\n{"type":"assistant","stop":"end","content":[{"type":"text","text":"ok"}]}'
else
  response='{"type":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"perf_call","name":"perf","input":{}}]}'
fi
print -r -- "$response"
EOF
cat >"$tmp/shellfish/tools/perf/manifest.json" <<'EOF'
{"description":"Performance fixture","input_schema":{"type":"object","additionalProperties":false},"sandbox":false}
EOF
cat >"$tmp/shellfish/tools/perf/run" <<'EOF'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- 'tool result'
EOF
chmod +x "$tmp/bin/jq" "$tmp/shellfish/providers/perf/run" "$tmp/shellfish/tools/perf/run"

# One hook per lifecycle. The unsandboxed tool skips permission_request.
typeset lifecycle
for lifecycle in session_start user_prompt_submit pre_tool_use post_tool_use stop; do
  mkdir -p "$tmp/shellfish/hooks/$lifecycle"
  print -r -- "{\"on\":\"$lifecycle\"}" >"$tmp/shellfish/hooks/$lifecycle/manifest.json"
  print -rl -- '#!/usr/bin/env zsh' 'cat >/dev/null' >"$tmp/shellfish/hooks/$lifecycle/run"
  chmod +x "$tmp/shellfish/hooks/$lifecycle/run"
done

print -r -- '{"provider":"perf","request":{"model":"perf"}}' >"$tmp/shellfish/models/default.jsonc"
cat >"$tmp/shellfish/profiles/default.jsonc" <<'EOF'
{
  "tools":["perf"],
  "hooks":["session_start","user_prompt_submit","pre_tool_use","post_tool_use","stop"]
}
EOF
print -rl -- SHELLFISH_MAX_REQUESTS_PER_TURN=8 \
  SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST=16 SHELLFISH_MAX_CAPTURE_BYTES=65536 \
  >"$tmp/shellfish/.env"

typeset metrics="$tmp/metrics.tsv" counts="$tmp/counts.tsv"
typeset jq_log="$tmp/jq-log" stderr="$tmp/stderr" stdout="$tmp/stdout"
typeset session="$tmp/session.jsonl" existing_input="$tmp/existing.jsonl" request_input="$tmp/request.jsonl"
typeset base_path=$PATH run_path=$PATH
typeset -a cases=( fresh_session existing_session create request )
typeset -A labels=( fresh_session 'Fresh session' existing_session 'Existing session'
  create 'Create session' request 'Request' )
printf 'case\trun\tmilliseconds\n' >"$metrics"
printf 'case\trun\tcore_jq\n' >"$counts"
: >"$jq_log"
typeset -gx SHELLFISH_PERF_JQ=$commands[jq]
typeset -gx SHELLFISH_PERF_JQ_LOG=$jq_log
# Use the fixture's limits rather than exported overrides.
unset SHELLFISH_MAX_REQUESTS_PER_TURN SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST \
  SHELLFISH_MAX_CAPTURE_BYTES SHELLFISH_MAX_CONTENT_BYTES

prepare_case() {
  case $1 in
    fresh_session|create) rm -f -- "$session" "$session.lock" ;;
    existing_session) cp -- "$existing_input" "$session"; : >"$session.lock" ;;
  esac
}

invoke_case() (
  local input=/dev/null
  local -a args
  case $1 in
    fresh_session) args=( run --session-out "$session" perf ) ;;
    existing_session) args=( run --session "$session" perf ) ;;
    create) args=( run --jsonl --session-create --session-out "$session" ) ;;
    request) args=( request ); input=$request_input ;;
  esac
  cd "$tmp/project" || return
  SHELLFISH_DIR="$tmp/shellfish" PATH="$run_path" \
    zsh -f "$root/bin/shellfish" "${args[@]}" <"$input" >"$stdout" 2>"$stderr"
)

validate_case() {
  local metric=$1
  integer turns=0
  if [[ $metric == request ]]; then
    "$SHELLFISH_PERF_JQ" -se '
      . == [{type:"assistant",stop:"tool_calls",content:[
        {type:"tool_call",id:"perf_call",name:"perf",input:{}}]}]
    ' "$stdout" >/dev/null
    return
  fi
  [[ $metric != fresh_session ]] || turns=1
  [[ $metric != existing_session ]] || turns=2
  "$SHELLFISH_PERF_JQ" -se --argjson turns "$turns" '
    map(.type) == (["session"] + ([range(0; $turns) |
      ["user","assistant","tool_result","assistant"]] | add // [])) and
    .[0].format_version == 1 and
    all(.[] | select(.type == "user");
      .content == [{type:"text",text:"perf"}]) and
    all(.[] | select(.type == "assistant");
      if .stop == "tool_calls" then
        .content == [{type:"tool_call",id:"perf_call",name:"perf",input:{}}]
      else .stop == "end" and .content == [{type:"text",text:"ok"}] end) and
    all(.[] | select(.type == "tool_result");
      .name == "perf" and .id == "perf_call" and .input == {} and
      .exit_code == 0 and .model_text == "tool result")
  ' "$session" >/dev/null
}

# Build fixed inputs once. Every measured invocation restores its own starting state.
prepare_case fresh_session
invoke_case fresh_session || { cat "$stderr" >&2; exit 1; }
validate_case fresh_session
cp -- "$session" "$existing_input"
prepare_case existing_session
invoke_case existing_session || { cat "$stderr" >&2; exit 1; }
validate_case existing_session
cp -- "$session" "$request_input"

{
  print -r -- "Platform: $(uname -srm)"
  print -r -- "zsh: $ZSH_VERSION"
  print -r -- "jq: $("$SHELLFISH_PERF_JQ" --version)"
  print -r -- "Shellfish: $(<"$root/VERSION")"
  print -r -- "Samples: $iterations per case, after one untimed warm-up per case"
  print -r -- 'Turns: 2 requests, 1 tool, 1 script per applicable lifecycle'
  print -r -- 'Latency is uninstrumented. Core jq counts use a separate pass and exclude fixture work.'
} >"$tmp/metadata"
cat "$tmp/metadata"
print

typeset metric phase
integer iteration offset index launches
float start elapsed
for metric in "${cases[@]}"; do
  prepare_case "$metric"
  invoke_case "$metric" || { cat "$stderr" >&2; exit 1; }
  validate_case "$metric"
done

for phase in latency counts; do
  run_path=$base_path
  [[ $phase != counts ]] || run_path="$tmp/bin:$base_path"
  for (( iteration = 1; iteration <= iterations; iteration++ )); do
    # Rotate the first case so one workload does not always run earliest.
    for (( offset = 0; offset < ${#cases}; offset++ )); do
      index=$(( (iteration - 1 + offset) % ${#cases} + 1 ))
      metric=$cases[index]
      typeset -gx SHELLFISH_PERF_RUN="$metric-$iteration"
      prepare_case "$metric"
      if [[ $phase == latency ]]; then
        start=$EPOCHREALTIME
        invoke_case "$metric" || { cat "$stderr" >&2; exit 1; }
        elapsed=$(( (EPOCHREALTIME - start) * 1000 ))
        printf '%s\t%d\t%.9f\n' "$metric" "$iteration" "$elapsed" >>"$metrics"
      else
        invoke_case "$metric" || { cat "$stderr" >&2; exit 1; }
        launches=$(grep -c -x -- "$SHELLFISH_PERF_RUN" "$jq_log")
        printf '%s\t%d\t%d\n' "$metric" "$iteration" "$launches" >>"$counts"
      fi
      validate_case "$metric" || {
        print -u2 -r -- "performance fixture did not complete: $phase/$metric/$iteration"
        exit 1
      }
    done
  done
  [[ $phase != latency || ! -s $jq_log ]] || {
    print -u2 -r -- 'jq counting contaminated latency measurements'
    exit 1
  }
done

printf '%-22s %6s %11s %9s %9s %11s\n' Case Runs 'Median (ms)' 'Min (ms)' 'Max (ms)' 'Core jq/run'
printf '%-22s %6s %11s %9s %9s %11s\n' ---------------------- ------ ----------- --------- --------- -----------
for metric in "${cases[@]}"; do
  awk -F '\t' -v metric="$metric" -v label="$labels[$metric]" -v expected="$iterations" '
    FILENAME == ARGV[1] && $1 == metric { samples[++runs] = $3 }
    FILENAME == ARGV[2] && $1 == metric {
      if (counted && $3 != launches) unstable = 1
      launches = $3; counted++
    }
    END {
      if (runs != expected || counted != expected || unstable || launches < 1) exit 1
      for (i = 2; i <= runs; i++) {
        value = samples[i]; j = i - 1
        while (j > 0 && samples[j] > value) { samples[j + 1] = samples[j]; j-- }
        samples[j + 1] = value
      }
      middle = int((runs + 1) / 2)
      median = runs % 2 ? samples[middle] : (samples[middle] + samples[middle + 1]) / 2
      printf "%-22s %6d %11.3f %9.3f %9.3f %11d\n", label, runs, median, samples[1], samples[runs], launches
    }
  ' "$metrics" "$counts" || {
    print -u2 -r -- "incomplete samples or unstable core jq count: $metric"
    exit 1
  }
done
