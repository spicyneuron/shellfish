---
name: audit-architecture
description: Use when the user requests an architecture or maintainability audit.
---
# Audit architecture

Audit whether the repository still serves Shellfish's goal: a small coding agent whose behavior and state can be understood in one sitting. Treat architecture as responsibilities, boundaries, and sources of truth, not merely code that works. Incremental changes can be locally plausible while introducing competing patterns, duplicate state, blurred ownership, or policy in the wrong layer.

The central design is an append-only session with each turn operated by one process. Clients present and replay it. The core preserves lifecycle guarantees. Profiles and harnesses assemble agent behavior. Backend adapters isolate provider protocols. Treat deviations from those boundaries as questions to investigate, not automatic defects.

## Scope

Match inspection depth to the request. For a whole-repository audit, first inventory the tree and documented contracts, then follow the major execution seams through their implementation, configuration, tests, and clients. Include configuration-dispatched and bundled code under `share/default/`. Do not infer reachability from static shell references alone. For a scoped audit, inspect the owning component plus its callers, boundaries, tests, and contract.

Maintain provisional notes while inspecting, but assess them against the full requested scope before reporting. Use documented intent and observable behavior together. Flag contradictions rather than assuming either is authoritative.

## Review order

Work from the highest useful level downward:

1. Sources of truth, lifecycle, execution flow, and failure recovery.
2. Ownership between the core, harness, adapters, clients, and shared code.
3. Dependency direction, public boundaries, and configuration-driven composition.
4. Maintenance risks such as duplicate state or policy, unnecessary layers, and hard-to-audit control flow.
5. Local design and naming only when no larger concern displaces them.

Distinguish intentional domain differences from accidental inconsistency. Confirm suspected duplication or contradiction through call sites, configuration, tests, and documented contracts. Prefer fewer concepts and direct ownership, but do not recommend unification merely for visual uniformity.

## Report

Do not edit code or produce a detailed implementation plan unless the user asks after discussing the audit. Return:

1. A brief assessment of the architecture as a whole.
2. One globally prioritized, numbered list of material findings.
3. Lower-level observations only when no more important issue displaces them.

For each finding, state the conflict, cite concrete files or symbols, explain the consequence, and offer a high-level solution direction. Separate evidence from judgment and identify uncertainty or trade-offs. Use stable finding IDs. Do not assign scores, manufacture findings, or present preferences as defects. If there are no material findings, say so.
