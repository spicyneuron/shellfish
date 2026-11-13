# Compaction prompt recommendation

Recommend a structured continuation handoff with a short causal timeline, not a longer chronological recap. The separate [prompt draft](compact-prompt.draft.md) is for review only. The shipped prompt and compaction behavior are unchanged.

## What we know

The current `share/commands/compact/prompt.md` already asks for user intent, constraints, rationale, exact identifiers, unfinished commitments, and next steps. Its weakness is organization and prioritization, not simply missing instructions. It requires one chronology without headings, asks for every major milestone, and gives no length guidance beyond concision. A long investigation can bury current state among superseded attempts. That is a risk inferred from the prompt, not a measured loss rate.

`share/commands/compact/run` sends the session plus this prompt to `shellfish request`. It preserves the first user message and last assistant text separately, with the generated summary inside `<timeline>`. Startup context and state updates also carry forward. The new session does not retain the intervening conversation as ordinary turns. On another compaction, the prior summary is therefore important evidence for older commitments. A prompt should update that evidence rather than accumulate layers of historical summaries.

The tracked compaction test checks assembly with a canned response, not summary quality. No tracked long-session transcript was available in the files inspected. I did not inspect gitignored/private session history or run a live provider request. The examples below are authored illustrations of the formats, not observed model outputs. We cannot yet conclude that the draft loses fewer facts on a real long session.

## Other coding agents

Sources checked on 2026-11-13. These are moving upstream branches, not guarantees about every installed version.

- [Codex's text compaction prompt](https://github.com/openai/codex/blob/main/codex-rs/prompts/templates/compact/prompt.md) asks for a structured handoff covering progress, decisions, constraints, remaining steps, and essential references. It favors continuation over exhaustive history. Its brevity leaves file selection and organization largely to the model. This compares the text prompt, not every Codex compaction backend.
- [Pi's compaction documentation](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/compaction.md) describes sections for goals, constraints, progress, decisions, next steps, and critical context. It also tracks read and modified files cumulatively and retains recent messages. Useful lesson: make state and file references explicit. Do not copy its whole design into Shellfish: file tracking and retaining recent turns are machinery changes outside this prompt task.

Neither source establishes that a particular format improves Shellfish's retention. Together they support trying a state-oriented handoff. The proposed short timeline retains Shellfish's useful emphasis on causal order.

## Options and examples

All examples describe the same fictional long session: a retry fix with repeated investigation and a later scope correction. Paths, symbols, and commands here are invented, not Shellfish files or test results.

### 1. Tighten the chronology

Keep today's format, explicitly distinguish current from superseded work, and finish with a checklist.

> User requested bounded retries in `src/client.ts`, preserving the public API. Early on, the user also requested release notes. The agent tried retrying every failure, then rejected it because POSTs could be duplicated. User narrowed retries to GET/HEAD. The agent changed `send()` and `tests/client.test.ts`. `npm test -- client` passed before the last abort change, not afterward. Final request: check cancellation. Remaining: rerun the focused tests, check cancellation during backoff, then write `CHANGELOG.md`. The caller-owned signal must not be replaced.

Smallest departure and easy to read for short work. Still makes the reader extract status, file ownership, and stale evidence from prose. Long sessions and repeated compactions encourage a growing story. Rank: second.

### 2. Structured handoff plus short timeline (recommended)

Separate present state from the few historical events needed to explain it.

> **Goal and constraints:** Bounded GET/HEAD retries, unchanged public API. Preserve caller-owned abort signal.
>
> **Current state:** `send()` and tests changed, uncommitted. Focused tests passed before the last abort edit. Cancellation check and the earlier release-note request remain unfinished.
>
> **Decisions:** No POST retries: duplicate side effects. Do not replace the caller's signal.
>
> **Relevant files:** `src/client.ts` (modified, reread `send()` for abort handling), `tests/client.test.ts` (modified, add cancellation case), `CHANGELOG.md` (not edited, release note still owed).
>
> **Causal timeline:** General retry attempt → duplicate-POST risk → user narrowed scope to GET/HEAD → abort edit after passing test run.
>
> **Next steps:** Check backoff cancellation, run `npm test -- client`, then write release notes. No known blocker.

Some repetition costs space, but the reader can immediately locate work, rationale, and evidence. A relevant-file list with reasons is more useful than every file ever opened. This is the best balance for Shellfish: prompt-only, readable, no new state or parser.

### 3. Minimal checkpoint and reread list

Prefer a very short current-state note, recovering almost everything from files.

> Continue bounded GET/HEAD retries, unchanged API, caller-owned signal. Modified/uncommitted: `src/client.ts` (`send()`), `tests/client.test.ts`. No POST retries due to duplicate side effects. Tests passed before the last abort edit only. Next: check cancellation during backoff, rerun `npm test -- client`, write the earlier-requested `CHANGELOG.md` note. Reread those three files. No known blocker.

Cheapest for a single narrow task. Harder to audit older requests, alternate approaches, or multiple workstreams. Rereading code cannot recover user intent or reasons never written there. Rank: third as a default, useful for unusually simple sessions.

## Length and defaults

Use a soft target of 500–1,000 words for a substantial session, less for simple work, more only for continuation-critical facts. This is an initial tuning choice, not a measured optimum or runtime cap. Six headings and terse bullets cost little compared with copying tool output or code. Summarize repeated searches and failed attempts, retain diagnostic details only when they change the next action.

Spend words on facts unavailable from rereading files: user corrections, unfinished promises, rejected approaches and reasons, exact blockers, permissions, and which revision a test actually checked. Paths are a recovery index, not a substitute for those facts. Preserve exact paths/symbols/commands when known, but do not invent an exhaustive inventory. Mark modified, read-only, planned, or unknown status from evidence. Avoid snapshots of code that the next agent can reread.

Keep every section in the draft so omissions are visible. Allow “None known” or “Not established” instead of guessing. Preserve the existing exclusions and separately retained boundary messages. The existing `<timeline>` wrapper can contain headings as text, so evaluating the draft need not change the runtime. Renaming that wrapper is not part of this recommendation.

## Validation before adopting

1. Select a consented long coding session with an early unfinished request, a user correction, a rejected approach, changed files, stale and current test evidence, and a pending decision. Also include a session already compacted once. Do not commit private transcripts.
2. Before generating summaries, independently list the facts a successor must know. Include exact paths, reasons, open commitments, what is not authorized, and the immediate next action.
3. Replay the same source with the current prompt and each candidate on the same model/settings, with several runs. Keep boundary messages and startup context identical. This comparison must not execute tools or modify the source session.
4. Record summary word/token counts, critical omissions, unsupported claims, and duplication. Give a fresh continuation agent only the resulting context and normal repository access. Check whether it finds the right files and proposes the right next action without reopening a rejected approach or claiming stale tests cover new edits.
5. Repeat compaction on the continuation to check older obligations survive. Prefer option 2 only if it preserves all critical facts without unsupported state and materially improves retrieval at an acceptable size. Otherwise revise the prompt, not the core.

No provider-quality claim is made until this replay is done. Tests were not run because this branch adds only the recommendation and an inactive Markdown draft. Runtime integration tests do not answer the retention question.
