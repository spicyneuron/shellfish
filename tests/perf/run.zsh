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
mkdir -p "$tmp/project" "$tmp/state" "$tmp/bin" "$tmp/config/backends/perf" \
  "$tmp/config/tools/perf"

cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env zsh
print -r -- "$SHELLFISH_PERF_RUN" >>"$SHELLFISH_PERF_JQ_LOG"
exec "$SHELLFISH_PERF_JQ" "$@"
EOF
cat >"$tmp/config/backends/perf/manifest.json" <<'EOF'
{"endpoint":"https://example.invalid/perf","environment":[]}
EOF
cat >"$tmp/config/backends/perf/run" <<'EOF'
#!/usr/bin/env zsh
request=$(cat)
if "$SHELLFISH_PERF_JQ" -e '.messages[-1].type == "tool_result"' <<<"$request" >/dev/null; then
  response=$'{"type":"_assistant_message_delta","index":0,"text":"ok"}\n{"type":"_assistant_end","stop":"end"}'
else
  response=$'{"type":"_assistant_tool_call_delta","index":0,"id":"perf_call","name":"perf","input":"{}"}\n{"type":"_assistant_end","stop":"tool_calls"}'
fi
print -r -- "$response"
EOF
cat >"$tmp/config/tools/perf/manifest.json" <<'EOF'
{"description":"Performance fixture","input_schema":{"type":"object","additionalProperties":false},"sandbox":false}
EOF
cat >"$tmp/config/tools/perf/run" <<'EOF'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- 'tool result'
EOF
chmod +x "$tmp/bin/jq" "$tmp/config/backends/perf/run" "$tmp/config/tools/perf/run"

# Exercise each hook reached by the turn with one no-op script. The unsandboxed
# tool does not reach permission_request.
typeset -a hook_events=(session_start user_prompt_submit pre_tool_use post_tool_use stop)
typeset event
for event in $hook_events; do
  mkdir -p "$tmp/config/hooks/$event/perf"
  cat >"$tmp/config/hooks/$event/perf/run" <<'EOF'
#!/usr/bin/env zsh
cat >/dev/null
EOF
  chmod +x "$tmp/config/hooks/$event/perf/run"
done

cat >"$tmp/config/shellfish.jsonc" <<EOF
{
  "default_profile":"perf",
  "theme_mode":"dark","theme_light":"light","theme_dark":"dark",
  "backends":{"perf":{"adapter":"perf"}},
  "harnesses":{"perf":{"tools":["perf"],"sandbox":false,
    "session_start":["perf"],"user_prompt_submit":["perf"],"permission_request":[],
    "pre_tool_use":["perf"],"post_tool_use":["perf"],"stop":["perf"],
    "max_requests_per_turn":8,"max_tool_calls_per_request":16,"max_capture_bytes":65536}},
  "profiles":{"perf":{"backend":"perf","harness":"perf","request":{"model":"perf"}}}
}
EOF

typeset turn_metrics="$tmp/turn-metrics" component_metrics="$tmp/component-metrics"
typeset jq_log="$tmp/jq-log" stderr="$tmp/stderr"
: >"$turn_metrics"
: >"$component_metrics"
: >"$jq_log"
typeset -gx SHELLFISH_PERF_JQ=$commands[jq]
typeset -gx SHELLFISH_PERF_JQ_LOG=$jq_log
integer iteration
for (( iteration = 1; iteration <= iterations; iteration++ )); do
  typeset -gx SHELLFISH_PERF_RUN="fresh-$iteration"
  float start=$EPOCHREALTIME
  (
    cd "$tmp/project"
    XDG_STATE_HOME="$tmp/state" PATH="$tmp/bin:$PATH" \
      zsh -f "$root/bin/shellfish" run --session-out "$tmp/session-$iteration.jsonl" \
      --config "$tmp/config/shellfish.jsonc" perf </dev/null >/dev/null 2>"$stderr"
  ) || { cat "$stderr" >&2; exit 1; }
  float elapsed=$(( (EPOCHREALTIME - start) * 1000 ))
  printf 'fresh_session\t%.9f\n' "$elapsed" >>"$turn_metrics"
  "$SHELLFISH_PERF_JQ" -se '
    ([.[] | select(.type == "assistant")] | length == 2) and
    ([.[] | select(.type == "tool_result")] | length == 1)
  ' "$tmp/session-$iteration.jsonl" >/dev/null || {
    print -u2 -r -- 'performance fixture did not complete its fresh turn'
    exit 1
  }
done

# A second turn separates opening an existing session from creating one.
for (( iteration = 1; iteration <= iterations; iteration++ )); do
  typeset -gx SHELLFISH_PERF_RUN="existing-$iteration"
  start=$EPOCHREALTIME
  (
    cd "$tmp/project"
    XDG_STATE_HOME="$tmp/state" PATH="$tmp/bin:$PATH" \
      zsh -f "$root/bin/shellfish" run --session "$tmp/session-$iteration.jsonl" \
      --config "$tmp/config/shellfish.jsonc" perf </dev/null >/dev/null 2>"$stderr"
  ) || { cat "$stderr" >&2; exit 1; }
  elapsed=$(( (EPOCHREALTIME - start) * 1000 ))
  printf 'existing_session\t%.9f\n' "$elapsed" >>"$turn_metrics"
  "$SHELLFISH_PERF_JQ" -se '
    ([.[] | select(.type == "assistant")] | length == 4) and
    ([.[] | select(.type == "tool_result")] | length == 2)
  ' "$tmp/session-$iteration.jsonl" >/dev/null || {
    print -u2 -r -- 'performance fixture did not complete its existing-session turn'
    exit 1
  }
done

for (( iteration = 1; iteration <= iterations; iteration++ )); do
  typeset -gx SHELLFISH_PERF_RUN="config-$iteration"
  start=$EPOCHREALTIME
  (
    cd "$tmp/project"
    XDG_STATE_HOME="$tmp/state" PATH="$tmp/bin:$PATH" \
      zsh -f "$root/bin/shellfish" config \
      --config "$tmp/config/shellfish.jsonc" >/dev/null 2>"$stderr"
  ) || { cat "$stderr" >&2; exit 1; }
  printf 'config\t%.9f\n' "$(( (EPOCHREALTIME - start) * 1000 ))" >>"$component_metrics"

  typeset -gx SHELLFISH_PERF_RUN="create-$iteration"
  start=$EPOCHREALTIME
  (
    cd "$tmp/project"
    XDG_STATE_HOME="$tmp/state" PATH="$tmp/bin:$PATH" \
      zsh -f "$root/bin/shellfish" create \
      --session-out "$tmp/create-$iteration.jsonl" \
      --config "$tmp/config/shellfish.jsonc" >/dev/null 2>"$stderr"
  ) || { cat "$stderr" >&2; exit 1; }
  printf 'create\t%.9f\n' "$(( (EPOCHREALTIME - start) * 1000 ))" >>"$component_metrics"

  typeset -gx SHELLFISH_PERF_RUN="build-request-$iteration"
  start=$EPOCHREALTIME
  (
    cd "$tmp/project"
    XDG_STATE_HOME="$tmp/state" PATH="$tmp/bin:$PATH" \
      zsh -f "$root/bin/shellfish" build-request \
      --session "$tmp/session-$iteration.jsonl" </dev/null >/dev/null 2>"$stderr"
  ) || { cat "$stderr" >&2; exit 1; }
  printf 'build_request\t%.9f\n' "$(( (EPOCHREALTIME - start) * 1000 ))" >>"$component_metrics"
done

integer fresh_count=0 existing_count=0 config_count=0 create_count=0 build_count=0
fresh_count=$(grep -c '^fresh-' "$jq_log") || fresh_count=0
existing_count=$(grep -c '^existing-' "$jq_log") || existing_count=0
config_count=$(grep -c '^config-' "$jq_log") || config_count=0
create_count=$(grep -c '^create-' "$jq_log") || create_count=0
build_count=$(grep -c '^build-request-' "$jq_log") || build_count=0
float fresh_per_run=$fresh_count existing_per_run=$existing_count
float config_per_run=$config_count create_per_run=$create_count build_per_run=$build_count
fresh_per_run=$(( fresh_per_run / iterations ))
existing_per_run=$(( existing_per_run / iterations ))
config_per_run=$(( config_per_run / iterations ))
create_per_run=$(( create_per_run / iterations ))
build_per_run=$(( build_per_run / iterations ))

print_metrics() {
  local heading=$1 samples=$2
  shift 2
  local metric label jq_per_run
  print -P -- "%B$heading%b"
  printf '%-22s %6s %10s %9s %9s %11s\n' Case Runs 'Mean (ms)' 'Min (ms)' 'Max (ms)' 'Core jq/run'
  printf '%-22s %6s %10s %9s %9s %11s\n' ---------------------- ------ ---------- --------- --------- -----------
  while (( $# >= 3 )); do
    metric=$1 label=$2 jq_per_run=$3
    shift 3
    awk -F '\t' -v metric="$metric" -v label="$label" -v jq_per_run="$jq_per_run" -v expected="$iterations" '
      $1 == metric {
        total += $2; if (!count || $2 < min) min = $2
        if (!count || $2 > max) max = $2; count++
      }
      END {
        if (count != expected) exit 1
        printf "%-22s %6d %10.3f %9.3f %9.3f %11.1f\n", label, count, total/count, min, max, jq_per_run
      }
    ' "$samples" || { print -u2 -r -- "incomplete metric: $heading/$metric"; exit 1; }
  done
  print
}

print_metrics 'Run performance (2 requests, 1 tool, 1 script/hook)' "$turn_metrics" \
  fresh_session 'Fresh session' $fresh_per_run \
  existing_session 'Existing session' $existing_per_run
print_metrics 'Public commands' "$component_metrics" \
  config 'Resolve configuration' $config_per_run \
  create 'Create session' $create_per_run \
  build_request 'Build request' $build_per_run
