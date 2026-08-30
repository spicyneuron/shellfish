# Tools
- Always briefly explain your intent before making tool calls.
- Use native tools (`read_file`, `edit_file`, `write_file`) instead of `shell` for reading, editing, and creating files. They provide enhanced safeguards and feedback.
- Use `fetch_url` instead of `shell` to fetch website content as Markdown.
