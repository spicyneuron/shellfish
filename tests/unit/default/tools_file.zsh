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

# Images return on fd 3 for the model to view, and other binary files are refused.
typeset small_png=iVBORw0KGgoAAAANSUhEUgAAAAQAAAACAQMAAABFZu8gAAAAA1BMVEUAgACc+aWRAAAADElEQVQI12NgYGAAAAAEAAEnNCcKAAAAAElFTkSuQmCC
typeset wide_png=iVBORw0KGgoAAAANSUhEUgAAB9AAAAAKAQMAAADW9Ff9AAAAA1BMVEUAgACc+aWRAAAAGUlEQVRIx+3BAQ0AAADCoPdPbQ43oAAA+DUJzgABnKClDgAAAABJRU5ErkJggg==
print -rn -- $small_png | base64 -d >"$tmp/small.png"
print -rn -- $wide_png | base64 -d >"$tmp/wide.png"
if (( $+commands[sips] || $+commands[magick] || ($+commands[identify] && $+commands[convert]) )); then
  # Images default to WebP, or JPEG where only sips, which cannot write WebP, is present.
  typeset encoded=webp png='{"read_file":{"image_format":"png"}}'
  (( $+commands[magick] || ($+commands[identify] && $+commands[convert]) )) || encoded=jpeg
  assert_equal "[image 4x2 $encoded]" "$(run_tool read_file '{"file_path":"small.png"}')"
  jq -e --arg prefix "data:image/$encoded;base64," '.content | length == 1 and
    .[0].type == "image" and (.[0].url | startswith($prefix))' \
    "$tmp/fd3" >/dev/null || fail 'read_file did not return an encoded image as content'
  : >|"$tmp/fd3"
  # An image already in the configured format and size is sent unchanged.
  assert_equal '[image 4x2 png]' \
    "$(SHELLFISH_CONFIG=$png run_tool read_file '{"file_path":"small.png"}')"
  jq -e --arg url "data:image/png;base64,$small_png" '.content == [{type:"image",url:$url}]' \
    "$tmp/fd3" >/dev/null || fail 'read_file re-encoded an image it could send unchanged'
  : >|"$tmp/fd3"
  assert_equal '[image 1568x8 png, downscaled from 2000x10]' \
    "$(SHELLFISH_CONFIG=$png run_tool read_file '{"file_path":"wide.png"}')"
  : >|"$tmp/fd3"
  assert_equal '[image 1000x5 png, downscaled from 2000x10]' \
    "$(SHELLFISH_CONFIG='{"read_file":{"image_format":"png","image_max_edge":1000}}' \
      run_tool read_file '{"file_path":"wide.png"}')"
  : >|"$tmp/fd3"
  print -r -- 'GIF89a is not an image' >"$tmp/fake.gif"
  assert_equal 'read_file: cannot decode image fake.gif' \
    "$(run_tool read_file '{"file_path":"fake.gif"}' || true)"
  assert_equal 'read_file: small.png is too large to view (84 bytes)' \
    "$(SHELLFISH_MAX_CONTENT_BYTES=200 SHELLFISH_CONFIG=$png \
      run_tool read_file '{"file_path":"small.png"}' || true)"
  for config in '{"read_file":{"image_format":"avif"}}' '{"read_file":{"image_quality":0}}' \
      '{"read_file":{"quality":40}}' '{"read_file":5}' '{"read_file":{"image_max_edge":0}}' \
      '{"read_file":{"image_max_edge":8001}}'; do
    assert_equal 'read_file: config.read_file allows image_format (webp, jpeg, png), image_quality (1-100), and image_max_edge (1-8000)' \
      "$(SHELLFISH_CONFIG=$config run_tool read_file '{"file_path":"small.png"}' || true)"
  done
fi
# Without a way to check an image, it is refused rather than stored unchecked.
# zsh -f keeps startup files from restoring a resizer to PATH.
mkdir -p "$tmp/bare"
for command in jq head od tr; do ln -sf "${commands[$command]}" "$tmp/bare/$command"; done
assert_equal 'read_file: viewing small.png needs sips or ImageMagick to check it' \
  "$(cd -- "$tmp" && print -rn -- '{"file_path":"small.png"}' |
    PATH=$tmp/bare "${commands[zsh]}" -f "$tools/read_file/run" 3>>"$tmp/fd3" || true)"
printf 'GIF\0binary' >"$tmp/blob.bin"
assert_equal 'read_file: blob.bin appears to be binary' \
  "$(run_tool read_file '{"file_path":"blob.bin"}' || true)"
assert_equal '' "$(<$tmp/fd3)" 'read_file wrote content for a refused read'

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

# File changes show their complete diff.
for tool in edit_file write_file; do
  jq -e '.user_preview_lines == "full"' "$tools/$tool/manifest.json" >/dev/null ||
    fail "$tool lost its full preview"
done

# Every bundled tool runs, and a sandboxed one carries its own policy.
for tool in "$tools"/*(/); do
  [[ -f $tool/run && -x $tool/run ]] || fail "${tool:t} has no executable run"
  ! jq -e '.sandbox == true' "$tool/manifest.json" >/dev/null ||
    [[ -f $tool/fence.jsonc ]] || fail "${tool:t} is sandboxed without a policy"
done

# Sandboxed tools that may write cannot create or change a Shellfish directory.
for policy in "$tools"/*/fence.jsonc; do
  jq -e '(.filesystem.allowWrite // []) == [] or
    (.filesystem.denyWrite | index("**/.shellfish") and index("**/.shellfish/**"))
  ' "$policy" >/dev/null || fail "${policy:h:t} may write Shellfish directories"
done
