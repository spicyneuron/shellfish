---
name: audit-architecture
description: Use when the user requests an architecture, maintainability, or cruft audit.
---
# Audit architecture

Audit whether the code has drifted Shellfish's goal: a minimalist coding agent whose behavior and state can be understood in one sitting. Treat architecture as responsibilities, boundaries, sources of truth, and the amount of code required to express them, not merely code that works. Incremental changes can be locally plausible while introducing competing patterns, duplicate state, blurred ownership, unnecessary branches, or policy in the wrong layer.

The central design is an append-only session with each turn operated by one process. Clients present and replay it. The core preserves lifecycle guarantees. Profiles and harnesses assemble agent behavior. Backend adapters isolate provider protocols. Treat deviations from those boundaries as questions to investigate, not automatic defects.

## Scope

Read every tracked, nonignored file in the requested subsystem. Include its implementation, tests, configuration, documentation, and bundled resources under `share/default/`. Do not sample files or stop after finding a major issue. Inspect callers and external boundaries outside the subsystem as needed to understand its contract. If the user does not name a subsystem, read the entire application, one subsystem at a time.

Inventory the scope before reading and maintain a coverage checklist. Run `./tests/run loc` to identify areas that warrant especially close review, but do not treat size alone as a defect. Maintain provisional notes while inspecting, but assess them against the complete requested scope before reporting. Use documented intent and observable behavior together. Flag contradictions rather than assuming either is authoritative.

## Review order

Work from the highest useful level downward:

1. Sources of truth, lifecycle, execution flow, and failure recovery.
2. Ownership between the core, harness, adapters, clients, and shared code.
3. Dependency direction, public boundaries, and configuration-driven composition.
4. Accidental concepts, duplicate state or policy, unnecessary layers, and hard-to-audit control flow.
5. Dead code, redundant validation or recovery, speculative handling, and dependencies that do not earn their cost.
6. Tests that mirror implementation or pin non-contractual output, and slow or brittle tests without credible coverage value.
7. Comments, documentation, and agent guidance that restate discoverable structure, preserve stale details, or obscure the actual rule.
8. Local design and naming only when no larger concern displaces them.

Distinguish intentional domain differences from accidental inconsistency. Confirm suspected dead code, duplication, or contradiction through call sites, configuration, dynamic dispatch, fixtures, platform-specific paths, tests, and documented contracts. Preserve boundary validation, failure handling, and valuable coverage. Prefer deletion, fewer concepts, direct control flow, and one clear owner, but do not recommend unification merely for visual uniformity.

## Report

Do not edit code or produce a detailed implementation plan unless the user asks after discussing the audit. Return:

1. A brief assessment of the architecture as a whole.
2. One globally prioritized, numbered list of material findings.
3. Lower-level cruft findings only when they remain material in that global priority order.

For each finding, state the conflict, cite concrete files or symbols, explain the consequence, and offer a high-level solution direction. Separate evidence from judgment and identify uncertainty or trade-offs. Use stable finding IDs. Do not assign scores, manufacture findings, or present preferences as defects. If there are no material findings, say so.
