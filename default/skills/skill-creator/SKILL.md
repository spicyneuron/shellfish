---
name: skill-creator
description: Create a reusable project-local skill. Use when the user asks to add or edit a skill for the current project.
---
# Create a project-local skill

Create the skill at `./.agents/skills/<name>/SKILL.md`, where `<name>` is a specific capability name using only lowercase letters, numbers, and single hyphens. The frontmatter `name` must exactly match the directory name.

Before writing, inspect nearby project instructions and any existing skills under `./.agents/skills/` so the new skill follows local conventions and does not duplicate existing capabilities.

Use this minimal structure:

```markdown
---
name: example-skill
description: Explain what the skill does and when the agent should use it.
---
# Example skill

Write direct, actionable instructions here.
```

Keep `name` at most 64 characters and `description` at most 1024 characters. Use single-line scalar values for both fields. Omit `disable-model-invocation` unless the user explicitly asks to hide the skill from automatic agent invocation.

Put the essential workflow in `SKILL.md`. Add supporting files under the same skill directory only when they are useful, and reference them with paths relative to that directory. Do not add scripts, dependencies, or broad permissions unless the requested workflow requires them.

After writing the skill, verify that:

- The directory and frontmatter names match.
- The description states both capability and trigger conditions.
- The instructions are concrete enough to follow without unstated project knowledge.
- Referenced files exist and use relative paths.
- The skill does not weaken project safety or permission boundaries.
