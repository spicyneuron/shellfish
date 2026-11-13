<compaction_request>
Write a continuation handoff for the conversation before the retained recent turns identified below. Those turns stay verbatim. Use them to judge what still matters, but do not recap them. Summarize only. Do not continue the task, answer its questions, or call tools.

The data below gives the retained prompt count and an excerpt of the first one. Count only user-authored prompts, not hook-only or image-only messages or this request. If the excerpt repeats, use the occurrence that starts the retained turns. The original user request is kept separately.

Audit every user request and assistant commitment, including earlier handoffs. Keep older open work until it is done, cancelled, or superseded. Distinguish approved decisions from proposals, attempts from results, and verified facts from assumptions. Never invent facts.

Use these sections, with terse bullets:

## Goal and constraints
Intent, acceptance criteria, scope, permissions, and corrections.

## Current state
Done, in-progress, and blocked work that still matters, including what tests cover. Working directory, branch, artifacts, and uncommitted changes when known.

## Decisions and open questions
Key choices and why, rejected approaches not to retry, unanswered questions, and pending approvals.

## Relevant files and references
Exact paths, why to reread each, and whether each was modified, only read, or is a planned edit. Keep critical symbols, values, commands, exact errors, and external references. Point to recoverable code rather than copying it.

## Causal timeline
Only the milestones that explain the current state, in order.

## Remaining work
Work the retained turns have not resolved, in order, with blockers and ownership when known. Do not add scope or assume permission.

Be concise, but keep continuation-critical facts. Merge older handoffs rather than nesting them. Skip the system prompt, session_start context, and this request. Return only the handoff.
</compaction_request>
