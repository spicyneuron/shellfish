<compaction_request>
Create a standalone continuation handoff so another agent can resume the work without the intervening conversation. Summarize the conversation, do not continue the task or answer its questions.

Audit every user request and assistant commitment, including older unfinished work and any earlier compacted context. Resolve corrections and superseded plans into the current state. Preserve the reasons for decisions that still affect continuation. Do not turn a proposal, attempted action, or unverified claim into an approved decision or completed result.

Use these sections, with terse bullets. Keep each heading. Write “None known” or “Not established” where appropriate rather than inventing facts.

## Goal and constraints
Capture the current user intent, acceptance criteria, scope boundaries, preferences, and permissions that affect the remaining work. Preserve material user corrections and task-specific injected context.

## Current state
Distinguish completed, in-progress, blocked, and not-started work, including every still-open request or commitment. Record observed outcomes and verification limits. Say whether tests checked the latest changes or an earlier state. Include the working directory, branch, commit, artifacts, and uncommitted changes when known and needed to continue. Do not guess their status.

## Decisions and open questions
Record pivotal decisions and their reasons, including rejected approaches that should not be retried. Separate user-approved choices from assistant defaults or proposals. Carry unanswered questions and pending approvals, with ownership when known.

## Relevant files and references
List every known file or reference the next agent needs to resume, with its exact path or identifier and a short reason to reread it. Distinguish modified files from read-only references and planned edits when known. Include relevant symbols, commands, values, and external references. Do not list incidental search hits or every file ever opened. Prefer reread pointers over copying recoverable code, but retain critical facts that are not stored in files.

## Causal timeline
Briefly explain the milestones needed to understand the current state, in chronological order. Consolidate repetitive investigation and omit obsolete detail unless it explains a constraint or decision. Do not repeat the full state or decision lists.

## Next steps
Give the immediate next action and ordered remaining work. Include exact commands or diagnostics when they matter, prerequisites, blockers, pending decisions, and ownership when known. Do not add new scope or assume permission not already granted.

Aim for 500–1,000 words for a substantial session, fewer for simple work. This is a soft target: never omit continuation-critical facts to meet it. Compress repetition and recoverable detail before open obligations, rationale, constraints, or verification evidence. On repeated compaction, update the prior handoff rather than nesting or copying stale summaries. Retain older open work until evidence shows it was completed, cancelled, or superseded.

Do not summarize the system prompt, session_start context, or this compaction request. The complete first user message and final assistant response are preserved separately. Do not repeat them verbatim, but include their material facts where needed for a coherent handoff.

Return only the structured handoff, without a preface.
</compaction_request>
