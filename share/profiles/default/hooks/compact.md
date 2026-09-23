<compaction_request>
Create a standalone, chronological summary of the conversation so another agent can seamlessly continue the work.

Capture every major milestone: user intent, requirements, constraints, decisions and rationale, actions and results, and other material changes in state. Preserve exact paths, symbols, commands, values, artifacts, and references when they matter for continuation.

Guidelines:

- Audit every user request and assistant commitment so older open work is not lost. Carry unfinished work and current status through the chronology.
- Consolidate repetitive activity, but retain the causal order needed to explain the outcome.
- Include injected context when it materially affected a request, decision, action, result, constraint, or current state.
- Do not summarize the system prompt, `session_start` context, or this `<compaction_request>`.
- The complete first user message and final assistant response will be preserved separately. Do not repeat them, but include their material facts when the timeline needs them.
- Never omit continuation-critical information just to make the result shorter.
- Ensure final entries are unambiguous about remaining tasks, unanswered questions, blockers, pending decisions, next steps, ordering, and ownership when known.

Return only the concise chronological summary, without a section heading or preface.
</compaction_request>
