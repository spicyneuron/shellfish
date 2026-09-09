# Shellfish

Shellfish is a small, auditable coding agent built from shell processes, text protocols, and an append-only log. Strive for simplicity: fewer concepts, direct control flow, and behavior that can be understood in one sitting.

This project is pre-release. Remove obsolete behavior rather than adding deprecation notices, compatibility paths, or tests for removed functionality.

## Design boundaries

- A session JSONL file is the authoritative state. Transcript records after its header are append-only. Every durable prefix must be valid, including an interrupted turn. Provider deltas, hook display, permissions, and presentation state are transient.
- One `shellfish run` process owns a complete turn, including hooks, provider requests, tools, persistence, recovery, and cleanup. This is a convention, not concurrent-writer protection. Clients invoke that boundary and replay the transcript. They do not embed the turn loop or maintain another copy of session state.
- The session header freezes the runtime. A session update may atomically replace it. Credentials and current presentation settings remain external. Do not add lifecycle or presentation records to the transcript.
- The core owns event ordering, canonical validation, persistence, recovery, and cleanup. Harnesses supply tools and workflow policy through configuration and lifecycle scripts. Keep bundled coding behavior out of the generic turn machinery.
- Backend adapters translate provider protocols into the normalized response stream. Keep provider-specific parsing, correlation, and protocol validation in the adapter. Tool calls remain inert until the core has assembled, validated, and persisted the complete assistant response.

## Code boundaries

- `bin/shellfish` dispatches public commands. Each top-level directory under `libexec/` is an independent program with private implementation. Reusable cross-component code belongs in `lib/`. Components compose through durable sessions and public `shellfish` commands, not another component's private files or symbols.
- `tests/unit/boundary.zsh` enforces component dependencies. Update the boundary deliberately when ownership changes. Do not bypass it with alternate path or symbol access.
- `share/default/` contains the bundled configuration and harness resources, including executable scripts. These are product behavior, not fixtures. `shellfish-server/` is a separate Go proxy and browser client over the same single-turn interface.
- jq module paths are repository-rooted. Load them with `sf_jq` from `lib/jq.zsh`, which runs jq from the installation root; jq resolves a module name against the working directory, so it would otherwise load the caller's copy. Only core components use jq modules. Bundled scripts validate their own input with plain jq, so nothing outside the core depends on the repository layout.
- Tools may be sandboxed. Hook scripts and backend adapters are trusted programs running with user permissions. Declare environment access per component and keep backend credentials out of hook and tool manifests.

## Working here

- Consult the focused contract before changing a subsystem: `docs/ARCHITECTURE.md`, `docs/RUN.md`, `docs/CONFIG.md`, `docs/HARNESS.md`, `docs/HOOKS.md`, `docs/BACKENDS.md`, or `docs/SERVER.md`.
- When in doubt, choose the simplest, most minimal implementation. We support the happy path and common cases. We do not need to defend against every theoretical edge case.
- For code changes, run the nearest focused test first, then bare `./tests/run`. Use `./tests/run pty` only for behavior requiring a terminal and run it outside the sandbox, where PTYs are available. Use `./tests/run server` for `shellfish-server/` changes. Do not run tests for documentation- or comment-only changes.
- In zsh, avoid names that collide with special parameters such as `status` and `commands`. When a command substitution's exit status matters, declare the variable first and assign it separately.
- Treat the worktree as shared. Only `git checkout`, `restore`, `reset`, or `stash` with user permission. Never discard or hide another agent's changes.
- Commit messages should start with a short, capitalized, imperative title without punctuation. The optional message body is reserved for details that would assist future debugging but not apparent in the diff's code or comments: motivation, constraints, counterintuitive decisions, alternatives considered, etc.
- Ignore gitignored files in all audits and reviews.
