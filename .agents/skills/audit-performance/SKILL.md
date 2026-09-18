---
name: audit-performance
description: Use when the user requests a performance audit or optimization.
---
# Audit performance

Measure the workload that matters before optimizing it. Shellfish's core is mostly zsh orchestration around external programs, where process startup often dominates. The TUI also has in-process work that scales with streamed content and viewport size. Match the measurement to the suspected bottleneck.

Preserve correctness at trust boundaries. The objective is less work, not weaker parsing, validation, framing, recovery, or cleanup.

## Approach

- Read every relevant tracked, nonignored file: implementation, tests, configuration, documentation, bundled resources, callers, and external boundaries. Inventory broader scope when needed, but follow the measured workload rather than reading unrelated files by default.
- Choose a representative operation and the dimensions along which its work can grow. `tests/perf/run.zsh` covers core turns and public commands; use focused temporary measurements for other paths.
- Record an unchanged baseline with repeated timings and process counts. For core turns, include `jq` launches per run. Treat counts as stable evidence and timings as noisy.
- Dynamically attribute a representative run to operations or call sites. Static search alone is insufficient. Exclude fixture-owned work and keep instrumentation out of the worktree when practical.
- Check meaningful growth axes, such as records, deltas, tool calls, hooks, requests, startup, or elapsed polling time. Compare more than one size when growth matters.
- For an audit, measure and report without editing. For optimization, make one demonstrated reduction at a time, then rerun the focused measurement and relevant tests.

## Guidance

- Eliminate work, combine queries, or amortize launches before micro-optimizing zsh.
- Skip empty optional work before preparing files, envelopes, or capture state.
- Combine repeated projections, batch bounded work, or use a persistent decoder for streams.
- Cache only reused state with a clear owner and lifecycle.
- For rendering, compare many small deltas with fewer large ones.
- Never parse JSON in zsh or with text heuristics merely to save a process. Preserve validation at CLI input, config and manifests, provider output, persistence reads, hook and tool output, and arbitrary-text encoding boundaries.
- Preserve explicit `false`. jq `//` treats both `null` and `false` as absent.

Prefer constant over per-item or elapsed-time work. Avoid broad refactors whose savings are not demonstrated.

Report the baseline, dynamic attribution, scaling evidence, and prioritized findings. After an optimization, also report before-and-after counts and timing distributions.
