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
(( $+commands[jq] )) || { print -u2 -r -- 'tests/metrics/exec.zsh requires jq'; exit 2; }

print -P -- '%BExec Performance%b'

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
cat >"$tmp/config/backends/perf/backend.json" <<'EOF'
{"endpoint":"https://example.invalid/perf","api_key_env":""}
EOF
cat >"$tmp/config/backends/perf/run" <<'EOF'
#!/usr/bin/env zsh
zmodload zsh/datetime
start=$EPOCHREALTIME
request=$(cat)
if jq -e '.messages[-1].role == "tool_result"' <<<"$request" >/dev/null; then
  phase=backend_final
  response='{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"ok"}]}'
else
  phase=backend_tool_call
  response='{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"perf_call","name":"perf","input":{}}]}'
fi
printf '%s\t%s\t%.9f\n' "$SHELLFISH_PERF_RUN" "$phase" "$(( (EPOCHREALTIME - start) * 1000 ))" \
  >>"$SHELLFISH_PERF_METRICS"
print -r -- "$response"
EOF
cat >"$tmp/config/tools/perf/tool.json" <<'EOF'
{"description":"Performance fixture","input_schema":{"type":"object","additionalProperties":false},"sandbox":false}
EOF
cat >"$tmp/config/tools/perf/run" <<'EOF'
#!/usr/bin/env zsh
zmodload zsh/datetime
start=$EPOCHREALTIME
cat >/dev/null
printf '%.9f\n' "$(( (EPOCHREALTIME - start) * 1000 ))" \
  >>"${0:A:h:h:h}/tool-metrics"
print -rn -- 'tool result'
EOF
chmod +x "$tmp/bin/jq" "$tmp/config/backends/perf/run" "$tmp/config/tools/perf/run"

cat >"$tmp/config/shellfish.jsonc" <<'EOF'
{
  "default_profile":"perf",
  "theme_mode":"dark","theme_light":"light","theme_dark":"dark",
  "backends":{"perf":{"adapter":"perf"}},
  "harnesses":{"perf":{"system":[],"tools":["perf"],"sandbox":false,
    "session_start":[],"user_prompt_submit":[],"permission_request":[],
    "pre_tool_use":[],"post_tool_use":[],"stop":[],
    "max_requests_per_turn":8,"max_tool_calls_per_request":16,"max_capture_bytes":65536}},
  "profiles":{"perf":{"backend":"perf","harness":"perf","request":{"model":"perf"}}}
}
EOF

typeset metrics="$tmp/metrics" tool_metrics="$tmp/config/tool-metrics"
typeset jq_log="$tmp/jq-log" stderr="$tmp/stderr"
: >"$metrics"
: >"$tool_metrics"
: >"$jq_log"
typeset -gx SHELLFISH_PERF_JQ=$commands[jq]
typeset -gx SHELLFISH_PERF_JQ_LOG=$jq_log
typeset -gx SHELLFISH_PERF_METRICS=$metrics
integer iteration
for (( iteration = 1; iteration <= iterations; iteration++ )); do
  typeset -gx SHELLFISH_PERF_RUN=$iteration
  float start=$EPOCHREALTIME
  (
    cd "$tmp/project"
    XDG_STATE_HOME="$tmp/state" PATH="$tmp/bin:$PATH" \
      zsh -f "$root/bin/shellfish" exec --session "$tmp/session-$iteration.jsonl" \
      --config "$tmp/config/shellfish.jsonc" perf >/dev/null 2>"$stderr"
  ) || { cat "$stderr" >&2; exit 1; }
  float elapsed=$(( (EPOCHREALTIME - start) * 1000 ))
  integer tool_count=$(wc -l <"$tool_metrics")
  (( tool_count == iteration )) || {
    print -u2 -r -- "incomplete timing phase: tool_fixture"
    exit 1
  }
  float tool_ms=$(tail -n 1 "$tool_metrics")
  printf '%s\ttool_fixture\t%.9f\n' "$iteration" "$tool_ms" >>"$metrics"
  float fixture_ms=$(awk -F '\t' -v run="$iteration" \
    '$1 == run && ($2 == "backend_tool_call" || $2 == "backend_final" || $2 == "tool_fixture") { total += $3 } END { print total + 0 }' \
    "$metrics")
  printf '%s\tend_to_end\t%.9f\n%s\tremainder\t%.9f\n' \
    "$iteration" "$elapsed" "$iteration" "$(( elapsed - fixture_ms ))" >>"$metrics"
done

typeset -a phases=(end_to_end backend_tool_call backend_final tool_fixture remainder)
printf '%-18s %7s %12s %12s %12s\n' Phase Samples 'Average (ms)' 'Minimum (ms)' 'Maximum (ms)'
printf '%-18s %7s %12s %12s %12s\n' ------------------ ------- ------------ ------------ ------------
typeset phase label
for phase in $phases; do
  label=${phase//_/ }
  awk -F '\t' -v phase="$phase" -v label="$label" -v expected="$iterations" '
    $2 == phase {
      total += $3; if (!count || $3 < min) min = $3
      if (!count || $3 > max) max = $3; count++
    }
    END {
      if (count != expected) exit 1
      label = toupper(substr(label, 1, 1)) substr(label, 2)
      printf "%-18s %7d %12.3f %12.3f %12.3f\n", label, count, total/count, min, max
    }
  ' "$metrics" || { print -u2 -r -- "incomplete timing phase: $phase"; exit 1; }
done

integer jq_count=$(wc -l <"$jq_log")
float jq_per_run=$jq_count
jq_per_run=$(( jq_per_run / iterations ))
printf '\njq processes/run: %.1f (%d total)\n' "$jq_per_run" "$jq_count"
print
