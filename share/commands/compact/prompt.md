<compaction_request>
Create a continuation handoff for the older conversation prefix identified below. The recent suffix is preserved verbatim. Use it to resolve corrections and what remains relevant, but do not recap it. Summarize, do not continue the task or answer its questions.

The boundary data appended below gives the number of retained user-authored turns and a JSON-quoted excerpt of the first retained prompt. Exclude this compaction request from the count, and do not count hook-only or image-only messages as user-authored prompts. If the excerpt repeats, use the occurrence that begins those last retained turns. Their associated hook context is also preserved. Summarize only the earlier conversation. The original user request is separately retained as historical context.

Audit every user request and assistant commitment, including earlier compacted context. Retain older open work until evidence shows it was completed, cancelled, or superseded. Distinguish user-approved decisions from proposals, attempted actions from completed results, and verified facts from assumptions. Never invent missing facts.

Use these sections with terse bullets:

## Goal and constraints
User intent, acceptance criteria, scope, permissions, and material corrections.

## Current state
Completed, in-progress, blocked, and outstanding work from the prefix that still matters. Include verification limits, especially whether tests cover the latest changes. Record working directory, branch, artifacts, and uncommitted changes only when known and useful.

## Decisions and open questions
Pivotal choices and their reasons, rejected approaches that should not be retried, unanswered questions, and pending approvals.

## Relevant files and references
Exact paths with a short reason to reread them. Distinguish modified files, read-only references, and planned edits. Preserve continuation-critical symbols, values, tool calls or commands, exact errors, and external references. Prefer reread pointers over copying recoverable code. Omit incidental search hits.

## Causal timeline
Only the milestones needed to explain the current state, in chronological order. Consolidate repetitive investigation and avoid repeating the other sections.

## Next steps
Immediate next action and ordered remaining work, including blockers, prerequisites, and ownership when known. Do not add scope or assume permission.

Keep the handoff concise without dropping continuation-critical facts. On repeated compaction, update older handoffs rather than nesting stale summaries. Do not summarize the system prompt, preserved session_start context, or this request. Return only the structured handoff, without a preface.
</compaction_request>
