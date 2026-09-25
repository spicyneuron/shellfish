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
assert_equal '{"user_preview_lines":"full"}' "$(<$tmp/fd3)" 'edit_file did not ask for a full preview'

# Skip unchanged edits.
assert_equal 'edit_file: file-tool.txt is already up to date' \
  "$(run_tool edit_file \
    '{"file_path":"file-tool.txt","old_string":"beta","new_string":"beta"}')"

# Write new files and report the change.
output=$(run_tool write_file '{"file_path":"created.txt","content":"created\n"}')
[[ -f "$tmp/created.txt" && $output == *+created* ]]
