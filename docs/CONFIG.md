# Configuration

Shellfish keeps configuration in one selected directory, typically `~/.shellfish/`. Profiles define agent behavior, models define inference requests, and runtime settings stay external to sessions.

| Home | Job | Frozen in a session |
| --- | --- | --- |
| [`models/NAME.jsonc`](MODELS.md) | Configures the provider, endpoint, and request parameters | Yes |
| [`profiles/NAME.jsonc`](PROFILE.md) | Selects system prompts, tools, commands, hooks, and sandbox settings | Yes |
| [`sandbox/NAME.jsonc`](PROFILE.md#sandbox) | Enables sandboxing and grants extra paths | Yes |
| `.env` and the environment | Credentials and core runtime settings | No |
| `tui.jsonc` | Themes and preview limits | No |

## Setup

```sh
shellfish init
# Replace MODEL in models/default.jsonc and add credentials to .env.
shellfish
```

`init` copies [`share/template/`](../share/template/) into the selected Shellfish directory, keeping any file that already exists. The profiles, model, sandbox file, system prompts, and starter skill are yours to edit. Bundled executable components remain available without copying them.

See [Profiles](PROFILE.md) for the starter agent and behavior customization, [Models](MODELS.md) for providers and credentials, and [Components](COMPONENTS.md) for writing your own extensions.

## Directories

One Shellfish directory holds profiles, models, sandbox files, system prompts, skills, components, `tui.jsonc`, `.env`, `sessions/` grouped by project directory, and `scratch/` for private temporary files.

Shellfish selects it in this order:

1. `SHELLFISH_DIR`, when set.
2. The nearest `.shellfish` directory above the working directory.
3. `~/.shellfish`.

For example, commands run from `/work/app` or its subdirectories use `/work/app/.shellfish` when it exists, unless `SHELLFISH_DIR` or a nearer `.shellfish` takes precedence. This directory replaces `~/.shellfish` for both configuration and session storage. Missing files do not fall back to `~/.shellfish`.

Only use configuration directories you trust. A project's `.shellfish` can select hooks, commands, and providers that run outside the tool sandbox, with your permissions and access to credentials.

`--continue` and `--resume` search the selected directory's sessions. Subagents, hooks, and tools receive the same `SHELLFISH_DIR`.

## References

Every reference in a profile, model, or sandbox file, and every option that takes one, follows one rule. A reference starting with `/`, `~/`, `./`, `../`, or `@` is a path, where `@` is the bundled root just as `~` is home. A relative path resolves against the file that contains it, or against the working directory on the command line. Anything else is a name, which resolves in its kind's directory, yours first, then bundled. Profile, model, and sandbox names gain `.jsonc`, and a name may be nested, such as `openai/sol`.

Your component shadows the bundled one of the same name. A path still reaches the bundled one, such as `@tools/shell`. A template profile works in place as `-p @template/profiles/readonly.jsonc`, though it names your system prompts and `sandbox/default.jsonc`.

See [Session configuration](ARCHITECTURE.md#the-transcript-is-the-state) for what freezes with a session and what stays live.

## Environment

Credentials and core runtime settings live in exported variables or `.env` in the Shellfish directory. Exported values win. Both stay external and are read for each invocation, so changes apply to existing sessions too.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SHELLFISH_MAX_REQUESTS_PER_TURN` | `100` | Provider requests per turn |
| `SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST` | `25` | Tool calls per response |
| `SHELLFISH_MAX_CAPTURE_BYTES` | `32768` | Bytes kept from each component stream, at least `64`, overridable by a manifest |
| `SHELLFISH_MAX_CONTENT_BYTES` | `5242880` | Bytes of tool control lines and of one call's model content, such as images |

Keep credentials in `.env` or the environment, not in profile `config`. See [Component trust](COMPONENTS.md#environment-and-trust) for which programs receive these values.

## Rendering

`tui.jsonc` merges over [`share/tui.jsonc`](../share/tui.jsonc) and is read on every run, so a reopened session renders with current settings.

| Field | Meaning |
| --- | --- |
| `theme_mode` | `auto`, `light`, or `dark` |
| `theme_light`, `theme_dark` | Selected names under `themes` |
| `themes` | Partial named `#RRGGBB` palettes |
| `preview_lines_reasoning` | Collapsed reasoning lines or `"full"` |
| `preview_lines` | Collapsed component-output lines or `"full"` |

`--verbose` temporarily makes both preview limits `"full"`. A hook or tool manifest's `user_preview_lines` overrides the global limit. See [`tui.schema.json`](../share/tui.schema.json) for the exact fields and [Presentation](COMPONENTS.md#presentation) for component templates.
