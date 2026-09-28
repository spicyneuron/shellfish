#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-tools-file

typeset tools="$ROOT/share/tools"
typeset output

run_tool() {
  local tool=$1 input=$2
  ( cd -- "$tmp" && print -rn -- "$input" | "$tools/$tool/run" 3>>"$tmp/fd3" )
}

# Read populated and empty files.
print -r -- alpha >"$tmp/file-tool.txt"
assert_equal $'L1-1 of 1\n1\talpha' \
  "$(run_tool read_file '{"file_path":"file-tool.txt"}')"
: >"$tmp/empty.txt"
assert_equal '(empty)' "$(run_tool read_file '{"file_path":"empty.txt"}')"

# Edit matching file content.
output=$(run_tool edit_file \
  '{"file_path":"file-tool.txt","old_string":"alpha","new_string":"beta"}')
[[ $output == '@@ -1 +1 @@'* && $output == *-alpha* && $output == *+beta* ]]
assert_equal '' "$(<$tmp/fd3)" 'edit_file wrote presentation control data'

# Skip unchanged edits.
assert_equal 'edit_file: file-tool.txt is already up to date' \
  "$(run_tool edit_file \
    '{"file_path":"file-tool.txt","old_string":"beta","new_string":"beta"}')"

# Write new files and report the change.
output=$(run_tool write_file '{"file_path":"created.txt","content":"created\n"}')
[[ -f "$tmp/created.txt" && $output == *+created* ]]

# Bundled manifests, not the core, choose each tool's status and skip wording.
typeset tool field running done skipped capture layout gap input
while IFS='|' read -r tool field running done skipped capture layout; do
  gap=$'\n'
  [[ $layout != inline ]] || gap=' '
  input='${input.'$field'}'
  jq -e --arg running "$running$gap$input" \
    --arg done "$done$gap$input"$'\n'"$capture" \
    --arg skipped "$skipped$gap$input"$'\n''${output.stderr}' '
      {user_text,user_text_done,user_text_skipped} ==
        {user_text:$running,user_text_done:$done,user_text_skipped:$skipped}
    ' "$tools/$tool/manifest.json" >/dev/null || fail "wrong bundled $tool status templates"
done <<'TABLE'
shell|command|Running shell command:|Ran shell command:|Did not run shell command:|${output.stdout}${output.stderr}
shell_readonly|command|Running read-only shell command:|Ran read-only shell command:|Did not run read-only shell command:|${output.stdout}${output.stderr}
read_file|file_path|Reading file:|Read file:|Did not read file:|${output.stdout}${output.stderr}
edit_file|file_path|Editing file:|Edited file:|Did not edit file:|${output.stdout}${output.stderr}
write_file|file_path|Creating file:|Created file:|Did not create file:|${output.stdout}${output.stderr}
search_web|query|Searching the web:|Searched the web:|Did not search the web:|${output.stdout}${output.stderr}
fetch_url|url|Fetching page:|Fetched page:|Did not fetch page:|${output.stdout}${output.stderr}
skill|name|Loading skill:|Skill load finished:|Did not load skill:|${output.stderr}
agent|operation|Running agent request:|Agent request finished:|Did not run agent request:|${output.stderr}|inline
TABLE
for tool in edit_file write_file; do
  jq -e '.user_preview_lines == "full"' "$tools/$tool/manifest.json" >/dev/null ||
    fail "$tool lost its full preview"
done
