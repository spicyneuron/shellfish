#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-tools-file

typeset tools="$ROOT/share/default/tools"
typeset output

run_tool() {
  local tool=$1 input=$2
  ( cd -- "$tmp" && print -rn -- "$input" | "$tools/$tool/run" )
}

# Allow editor diff directories.
for policy in edit_file write_file; do
  jq -e '.filesystem.denyWrite |
    all(.[]; test("^/(private/)?var/(tmp|folders)/") | not)' \
    "$tools/$policy/fence.jsonc" >/dev/null
done

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

# Limit diff context.
print -r -- $'one\ntwo\nthree\nfour\nfive\nsix\nseven' >"$tmp/context-diff.txt"
output=$(run_tool edit_file \
  '{"file_path":"context-diff.txt","old_string":"four","new_string":"changed"}')
[[ $output == *$' three\n-four\n+changed\n five'* ]]
[[ $output != *' two'* && $output != *' six'* ]]

# Skip unchanged edits.
assert_equal 'edit_file: file-tool.txt is already up to date' \
  "$(run_tool edit_file \
    '{"file_path":"file-tool.txt","old_string":"beta","new_string":"beta"}')"

# Diff new files without /dev/null.
mkdir "$tmp/diff-bin"
cat >"$tmp/diff-bin/diff" <<'ZSH'
#!/usr/bin/env zsh
for arg in "$@"; do
  [[ $arg != /dev/null ]] || {
    print -u2 -- 'diff: /dev/null: Operation not permitted'
    exit 2
  }
done
exec /usr/bin/diff "$@"
ZSH
chmod +x "$tmp/diff-bin/diff"
typeset saved_path=$PATH
PATH="$tmp/diff-bin:$PATH"
rehash
output=$(run_tool write_file '{"file_path":"created.txt","content":"created\n"}')
PATH=$saved_path
rehash
[[ $output == '@@ -0,0 +1 @@'* && $output == *+created* ]]

# Preserve newlines in paths.
typeset newline_path=$'trailing-newline\n'
run_tool write_file "$(jq -cn --arg path "$newline_path" \
  '{file_path:$path,content:"kept\n"}')" >/dev/null
[[ -f "$tmp/$newline_path" ]]
