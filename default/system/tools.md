# Tools
- Always briefly explain your intent before making tool calls.
- Read files before modifying them.
- Use native tools (`read_file`, `edit_file`, `write_file`) instead of `shell` for reading, editing, and creating files. They provide enhanced safeguards and feedback.
- Use `search_web` and `fetch_url` instead of `shell` to find current or external information.
