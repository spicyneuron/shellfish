---
name: skill-creator
description: Use when creating or editing project-local skills.
---
# Create a project-local skill

## 1. Starting Point

Match the process to how much the user has already decided:

- **High-level?** Interview them to understand their goals and constraints.
- **Partially settled?** Focus on open decisions and ambiguities.
- **Settled and procedural?** Move directly to writing the skill.

## 2. Design

Before writing, make sure you understand what a good result looks like.

- Clarify the purpose, success criteria, invocation conditions, non-goals, constraints, required steps, and important edge cases.
- Work through one meaningful decision at a time, starting from the high level and working through dependencies and details.
- When useful, give the user concrete options or examples, explain the trade-offs, and recommend an approach.
- Recap decisions as they are made. Start writing once only routine implementation details remain.

## 3. Write

Turn the agreed design into the shortest instructions that will reliably produce the intended behavior.

- Be precise about settled requirements, but leave room for judgment where the user wants flexibility. Do not introduce certainty or constraints the user did not choose.
- Use direct, unambiguous, information-dense language. Remove repetition, unnecessary background, and guidance the model can safely infer. All else equal, shorter is better.
- Remember that length costs tokens. The name and description load in every new session, and the full skill loads when invoked.
- Make the description the shortest clear answer to: When should this skill be used? Prefer `Use when ...` or `Invoke when ...`.
- Open the skill body with a brief section that captures its intent.
- Inspect project instructions and existing skills under `./.agents/skills/` so the skill follows local conventions and does not duplicate an existing capability.
- Create the skill at `./.agents/skills/<name>/SKILL.md`. Choose a specific name using only lowercase letters, numbers, and single hyphens.
- Match the frontmatter `name` to the directory name. Keep `name` at most 64 characters and `description` at most 1024 characters. Use single-line scalars.
- Omit `disable-model-invocation` unless the user asks to hide the skill from automatic invocation.
- Keep the essential workflow in `SKILL.md`. Add supporting files with relative paths only when they are useful. Add scripts, dependencies, or broad permissions only when the workflow requires them.

## 4. Verify

Read the finished skill once more and confirm that:

- It reflects the decisions made with the user.
- The directory and frontmatter names match.
- The description succinctly answers when the skill should be used and contains no fluff.
- The opening section briefly captures the skill's intent.
- The instructions are concise, unambiguous, and usable without unstated project knowledge.
- Settled requirements are specific, while deliberately open-ended behavior remains open.
- Every referenced file exists and uses a relative path.
- The skill preserves existing safety and permission boundaries.
