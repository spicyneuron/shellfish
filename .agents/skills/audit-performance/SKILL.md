---
name: audit-performance
description: Use when the user requests a performance audit or optimization.
---
# Audit performance

Shellfish is mostly Zsh orchestration around external programs. Process startup—especially repeated `jq`—usually dominates hot-path cost more than shell computation. Treat spawned-process count as a first-class metric: eliminate work, combine queries, or amortize launches before micro-optimizing Zsh. Preserve `jq` at trust boundaries. The goal is fewer processes, not weaker parsing or validation.

## Workflow

1. Run `./tests/run metrics` unchanged. Record `jq processes/run`, end-to-end, and remainder timing. Process count is deterministic; timing is noisy.
2. Trace one representative `tests/metrics/exec.zsh 1` run to attribute dynamic launches by arguments and call site. Static `rg` is insufficient. Exclude fixture-owned processes; keep instrumentation temporary.
3. Rank launches by frequency and scaling: per event, tool call, tool, hook, request, turn, then startup-only.
4. Make one coherent reduction at a time. Rerun the focused metric and nearest tests, then `./tests/run unit`.
5. Report old/new process counts and timing distribution. Commit only after review.

## Patterns

- Skip empty optional work before JSON envelopes, scratch files, or capture state. Preserve lock and boundary preconditions.
- Combine projections of the same JSON in one `jq`. Emit NUL-delimited fields plus an `ok` sentinel; validate field count before assignment.
- Batch per-item inspection: collect inputs, invoke `jq` once, verify output count, then continue the shell loop.
- Cache reused frozen runtime/session metadata. Populate, refresh, and clear it with the owning lifecycle; missing cache data must not weaken validation.
- Keep validation at CLI/external input, config/manifest, provider, persistence-read, hook/tool output, and arbitrary-text JSON-encoding boundaries. Remove only repeated validation on trusted internal paths.
- For unbounded streams, prefer one persistent decoder per stream over one `jq` per event. Preserve framing, cancellation, malformed-input handling, and cleanup.
- Never parse JSON in Zsh or with text heuristics merely to save a process. Move, combine, or amortize the authoritative `jq` operation.
- Preserve error attribution and explicit `false`; jq `//` treats both `null` and `false` as absent.

Prefer constant over per-item process counts. Avoid duplicate authoritative state and broad refactors whose savings are not measured.
