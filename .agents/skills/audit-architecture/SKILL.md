---
name: audit-architecture
description: Use when the user requests an architecture or maintainability audit.
---
# Audit architecture

Audit the repository's design integrity in support of Shellfish's goal of remaining minimal and auditable. Treat architecture as a coherent set of responsibilities, boundaries, and decisions—not merely code that works. Incremental, especially AI-generated, changes can be locally plausible while creating system-wide drift through competing patterns, duplicate implementations, blurred ownership, leaky abstractions, contradictory contracts, and structures preserved without a current reason.

Find the highest-level material problems first, then descend through maintenance concerns to local elegance and aesthetics when the larger architecture is sound. Favor fewer concepts, clear scope, and code whose structure can be readily explained and justified. The result is a prioritized basis for discussion, not an immediate editing or implementation task.

## Scope

Unless otherwise instructed, inspect the whole repository in sections: root-level contracts and metadata, `docs/`, `bin/`, `lib/`, `default/` and `template/`, `tests/`, then `cmd/shellfish-server/`. Inventory each section and read its relevant source, tests, configuration, and documentation before moving to the next. A section-scoped request does not require inspecting the others.

Maintain provisional notes while inspecting, but assess them against the whole requested scope before reporting. Use documented architecture and observable behavior together; flag contradictions rather than assuming either is authoritative.

## Review order

Work from the highest useful level downward:

1. System boundaries, sources of truth, lifecycle, execution flow, and ownership.
2. Module responsibilities, dependency direction, abstraction boundaries, and competing patterns.
3. Maintenance risks such as duplication, dispersed policy, unnecessary layers, and hard-to-audit control flow.
4. Local design, naming, unnecessary complexity, and other elegance or aesthetic concerns.

At each level, look for meaningful problems before descending. Do not dilute structural findings with optimizations or nitpicks. If the higher levels are coherent, continue downward rather than inventing an architectural concern or returning an empty audit.

Distinguish intentional domain differences from accidental inconsistency. Confirm suspected duplication or contradiction through call sites, configuration, tests, and documented contracts. Prefer simpler ownership and fewer concepts, but do not recommend unification merely for visual uniformity.

## Report

Do not edit code or produce a detailed implementation plan unless the user asks after discussing the audit. Return:

1. A brief assessment of the architecture as a whole.
2. One globally prioritized, numbered list of material findings.
3. Lower-level observations only when no more important issue displaces them.

For each finding, state the conflict, cite concrete files or symbols, explain the architectural or maintenance consequence, and offer a high-level solution direction. Keep remedies for structural problems at the level of boundaries and responsibilities; use concrete code-level advice only for local findings. Separate evidence from judgment and identify uncertainty or trade-offs.

Use stable finding IDs so the list is easy to discuss. Do not assign numeric scores, manufacture findings, or present speculative aesthetics as objective defects. If the audit yields no material findings, say so explicitly.
