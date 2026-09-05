---
name: cleanup-cruft
description: Use when the user requests code cleanup or cruft removal.
---
# Clean up cruft

Remove code and guidance that no longer earn their complexity. Shellfish is intended to remain small and auditable, so prefer deletion, direct control flow, and one clear owner over replacement abstractions.

## Scope

Match the investigation to the request. For a scoped cleanup, inspect the owning code together with its callers, configuration, tests, and documentation. For a repository-wide cleanup, inventory the tree first and work through coherent ownership or execution slices rather than following a fixed directory order. Include dynamically selected hooks, tools, adapters, and bundled resources under `share/default/` when checking reachability.

Look for:

- Dead code, unused files, redundant layers, speculative abstractions, and duplicate state or policy.
- Validation or recovery repeated after an established internal guarantee.
- Tautological tests, tests that mirror implementation, and assertions that pin non-contractual output.
- Slow or brittle tests whose maintenance cost outweighs credible coverage.
- Comments that restate code, narrate old implementations, or over-explain a simple constraint.
- Documentation and agent guidance that duplicate discoverable structure, preserve stale details, or obscure the actual rule.

Confirm candidates through configuration, dynamic dispatch, public interfaces, fixtures, and platform-specific paths, rather than only static references. Preserve behavior, boundary validation, failure handling, and valuable coverage. Do not unify code whose differences reflect distinct ownership or lifecycle.

Make the smallest coherent cleanup in each ownership slice and run its focused checks. Leave uncertain candidates unchanged rather than inventing a rationale for removal. For changes spanning several natural boundaries, propose reviewable chunks before editing.

Report what was removed or simplified, the checks run, and any deferred candidates with evidence and a recommendation.
