---
name: cleanup-cruft
description: Use when user requests code cleanup or cruft removal.
---
# Clean up cruft

Inspect the relevant code, tests, and documentation to remove or simplify cruft. Look for:

- Dead code, redundant layers, speculative abstractions, duplicate validation, and checks already guaranteed upstream.
- Tautological or duplicate tests, tests that mirror implementation, and assertions that pin incidental details that are not themselves part of a contract.
- Slow or brittle tests whose maintenance cost outweighs credible coverage.
- Comments that restate code, narrate old implementations or model discussion, or use more words than a current non-obvious constraint requires.
- Documentation that's incorrect, inconsistent, or ambiguously worded.

Unless otherwise instructed, check the following sections in order: `AGENTS.md`, `lib/`, `default/`, `tests/`, `cmd/shellfish-server/`, and `docs/`.

Complete one section before starting the next: inventory it, read every file, then review and clean candidates one at a time. A section-scoped request does not require inspecting the others.

Confirm dead code has no hidden consumer through configuration, dynamic dispatch, public interfaces, fixtures, or platform-specific paths. Preserve intended behavior and valuable coverage. Prefer deletion and direct code over replacement abstractions.

Make the smallest coherent cleanup and run focused project checks. Leave uncertain candidates unchanged and continue all obvious cleanup in scope. Afterward, report what changed and present the deferred candidates with evidence and a recommendation.
