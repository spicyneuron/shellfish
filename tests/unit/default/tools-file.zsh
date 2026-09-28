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
check_text() {
  local tool=$1 input=$2 running=$3 done=$4 skipped=$5
  jq -L "$ROOT" -en --slurpfile manifest "$tools/$tool/manifest.json" \
    --arg name "$tool" --argjson input "$input" \
    --arg running "$running" --arg done "$done" --arg skipped "$skipped" '
      include "lib/profile";
      $manifest[0] as $m |
      ($m | tool_manifest) and
      ($m.user_text | render_template(.; $name; $input; {}; {})) == $running and
      ($m.user_text_done | render_template(.; $name; $input;
        {stdout:"result\n",stderr:"warning\n",exit_code:7}; {})) == $done and
      ($m.user_text_skipped | render_template(.; $name; $input;
        {stdout:"",stderr:"not allowed",exit_code:126}; {})) == $skipped
    ' >/dev/null || fail "wrong bundled $tool status text"
}
check_text shell '{"command":"echo ok"}' \
  $'Running shell command:\necho ok' \
  $'Ran shell command:\necho ok\nresult\nwarning\n' \
  $'Did not run shell command:\necho ok\nnot allowed'
check_text shell_readonly '{"command":"pwd"}' \
  $'Running read-only shell command:\npwd' \
  $'Ran read-only shell command:\npwd\nresult\nwarning\n' \
  $'Did not run read-only shell command:\npwd\nnot allowed'
check_text read_file '{"file_path":"notes.txt"}' \
  $'Reading file:\nnotes.txt' $'Read file:\nnotes.txt\nresult\nwarning\n' \
  $'Did not read file:\nnotes.txt\nnot allowed'
check_text edit_file '{"file_path":"notes.txt"}' \
  $'Editing file:\nnotes.txt' $'Edited file:\nnotes.txt\nresult\nwarning\n' \
  $'Did not edit file:\nnotes.txt\nnot allowed'
check_text write_file '{"file_path":"new.txt"}' \
  $'Creating file:\nnew.txt' $'Created file:\nnew.txt\nresult\nwarning\n' \
  $'Did not create file:\nnew.txt\nnot allowed'
check_text search_web '{"query":"shellfish guide"}' \
  $'Searching the web:\nshellfish guide' \
  $'Searched the web:\nshellfish guide\nresult\nwarning\n' \
  $'Did not search the web:\nshellfish guide\nnot allowed'
check_text fetch_url '{"url":"https://example.com"}' \
  $'Fetching page:\nhttps://example.com' \
  $'Fetched page:\nhttps://example.com\nresult\nwarning\n' \
  $'Did not fetch page:\nhttps://example.com\nnot allowed'
check_text skill '{"name":"review"}' \
  $'Loading skill:\nreview' $'Skill load finished:\nreview\nwarning\n' \
  $'Did not load skill:\nreview\nnot allowed'
check_text agent '{"operation":"inspect"}' \
  'Running agent request: inspect' $'Agent request finished: inspect\nwarning\n' \
  $'Did not run agent request: inspect\nnot allowed'
for tool in edit_file write_file; do
  jq -e '.user_preview_lines == "full"' "$tools/$tool/manifest.json" >/dev/null ||
    fail "$tool lost its full preview"
done
