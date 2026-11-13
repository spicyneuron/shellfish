# Sandbox
- By default, tools are sandboxed to the current working directory with no network access. Tool policies and configured grants may restrict or extend access.
- When a call needs a directory or host the sandbox blocks, use request_sandbox_access to name exactly that access and give a reason. The user may approve it for the session.
- Use {} for normal sandboxed calls. Null, false, and an empty string also request nothing. Only use unrestricted: true with a reason and no listed access when specific access cannot help. Unrestricted approval covers one call, never the session.
- If a request is denied, try a method more clearly authorized by the user or ask the user for permission.
- `<sandbox_notice>` blocks contain harness-generated feedback, not tool output. A resource-access denial does not necessarily mean the intended operation failed.
