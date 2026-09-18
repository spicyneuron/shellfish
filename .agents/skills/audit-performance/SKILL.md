---
name: audit-performance
description: Use when the user requests a performance audit or optimization.
---
# Audit performance

Measure the workload that matters before optimizing it. Shellfish's core is mostly zsh orchestration around external programs, where process startup, especially repeated `jq`, often dominates. The TUI also has in-process rendering paths whose cost scales with deltas, lines, and viewport work. Do not apply process-count advice to a rendering bottleneck or timing advice to an unmeasured path.

Preserve correctness at trust boundaries. The objective is less work, not weaker parsing, validation, framing, recovery, or cleanup.

## Workflow

1. Read every tracked, nonignored file in the requested subsystem, including its implementation, tests, configuration, documentation, and bundled resources. Inspect callers and external boundaries outside the subsystem as needed to understand its workload. If the user does not name a subsystem, read the entire application.
2. Choose the representative operation and scaling axis. Use `tests/perf/run.zsh` for core turns and public commands, or `./tests/run perf` for its default repeated sample. Design a focused temporary measurement when that fixture does not exercise the requested path.
3. Record an unchanged baseline. For turns, capture `jq` processes per run and end-to-end time. Treat process counts as deterministic and timings as noisy. Compare repeated samples.
4. Trace one representative run to attribute dynamic cost by arguments and call site. Use `tests/perf/run.zsh 1` for one core sample. Static `rg` alone is insufficient, and fixture-owned processes must be excluded. Keep instrumentation temporary.
5. Rank costs by frequency and growth: per delta, record, tool call, tool, hook, provider request, turn, or startup. Check behavior at more than one input size when the path can scale.
6. Make one coherent reduction at a time. Rerun the focused measurement and nearest tests, then bare `./tests/run` for code changes.
7. Report the old and new workload, counts, and timing distribution. Commit only after review.

## Patterns

- Eliminate work, combine queries, or amortize launches before micro-optimizing zsh.
- Skip empty optional work before creating JSON envelopes, scratch files, or capture state. Preserve lifecycle preconditions.
- Combine projections of the same JSON in one `jq`. When returning multiple fields, use unambiguous framing and validate the result before assignment.
- Batch per-item inspection, or use one persistent decoder for an unbounded stream. Preserve malformed-input handling, cancellation, and cleanup.
- Cache only reused state with a clear owner. Populate, refresh, and clear it with that lifecycle. Missing cache data must not weaken validation.
- In rendering, test both many small deltas and fewer large ones. Avoid repeating work for unchanged content without weakening committed scrollback or recovery semantics.
- Never parse JSON in zsh or with text heuristics merely to save a process. Preserve validation at CLI input, config and manifests, provider output, persistence reads, hook and tool output, and arbitrary-text encoding boundaries.
- Preserve explicit `false`. jq `//` treats both `null` and `false` as absent.

Prefer constant over per-item work. Avoid broad refactors whose savings are not demonstrated by the chosen workload.
