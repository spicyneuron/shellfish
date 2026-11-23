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
typeset wide_png=iVBORw0KGgoAAAANSUhEUgAACcQAAAAKAQMAAACqx11pAAAAA1BMVEUAgACc+aWRAAAAGklEQVR42u3BgQAAAADDoPlTX+EAVQEAAPwGDEQAAWCjMYgAAAAASUVORK5CYII=
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
  assert_equal '[image 2000x8 png, downscaled from 2500x10]' \
    "$(SHELLFISH_CONFIG=$png run_tool read_file '{"file_path":"wide.png"}')"
  : >|"$tmp/fd3"
  assert_equal '[image 1000x4 png, downscaled from 2500x10]' \
    "$(SHELLFISH_CONFIG='{"read_file":{"image_format":"png","image_max_edge":1000}}' \
      run_tool read_file '{"file_path":"wide.png"}')"
  : >|"$tmp/fd3"
  print -r -- 'GIF89a is not an image' >"$tmp/fake.gif"
  assert_equal 'read_file: cannot decode image fake.gif' \
    "$(run_tool read_file '{"file_path":"fake.gif"}' || true)"
  { cat "$tmp/small.png"; head -c 1024 /dev/zero; } >"$tmp/padded.png"
  assert_equal 'read_file: padded.png is too large to view (1108 bytes)' \
    "$(SHELLFISH_MAX_CONTENT_KB=1 SHELLFISH_CONFIG=$png \
      run_tool read_file '{"file_path":"padded.png"}' || true)"
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
assert_equal $'@@ -1 +1 @@\n-alpha\n+beta' "$output"
assert_equal '' "$(<$tmp/fd3)" 'edit_file wrote presentation control data'

# Skip unchanged edits.
assert_equal 'edit_file: file-tool.txt is already up to date' \
  "$(run_tool edit_file \
    '{"file_path":"file-tool.txt","old_string":"beta","new_string":"beta"}')"

# Pattern characters in old_string match literally.
print -r -- 'a [x] * b' >"$tmp/literal.txt"
run_tool edit_file '{"file_path":"literal.txt","old_string":"[x] *","new_string":"y"}' >/dev/null
assert_equal 'a y b' "$(<$tmp/literal.txt)"

# Without an exact match, edits follow the file's CRLF line endings and quote style.
printf 'one\r\ntwo\r\n' >"$tmp/crlf.txt"
run_tool edit_file '{"file_path":"crlf.txt","old_string":"one\ntwo","new_string":"1\n2"}' >/dev/null
[[ "$(cat -v -- $tmp/crlf.txt)" == $'1^M\n2^M' ]] || fail 'edit_file lost CRLF line endings'
print -r -- 'say “hi” and it’s' >"$tmp/quotes.txt"
run_tool edit_file \
  '{"file_path":"quotes.txt","old_string":"say \"hi\" and it\u0027s","new_string":"done"}' >/dev/null
assert_equal 'done' "$(<$tmp/quotes.txt)"
print -r -- '‘a’ and ‘a’' >"$tmp/twice.txt"
assert_equal 'edit_file: old_string appears 2 times in twice.txt; include more surrounding context or set replace_all' \
  "$(run_tool edit_file '{"file_path":"twice.txt","old_string":"\u0027a\u0027","new_string":"b"}' || true)"

# Write new files and report the change.
output=$(run_tool write_file '{"file_path":"created.txt","content":"created\n"}')
assert_equal $'@@ -0,0 +1 @@\n+created' "$output"
assert_equal created "$(<$tmp/created.txt)"

# Overwrite existing files and report the change against their old contents.
output=$(run_tool write_file '{"file_path":"created.txt","content":"replaced\n"}')
assert_equal $'@@ -1 +1 @@\n-created\n+replaced' "$output"
assert_equal replaced "$(<$tmp/created.txt)"
assert_equal 'write_file: created.txt is already up to date' \
  "$(run_tool write_file '{"file_path":"created.txt","content":"replaced\n"}')"

# Diff the contents of a symlink target without treating the symlink as a change.
ln -s created.txt "$tmp/linked.txt"
chmod +x "$tmp/created.txt"
output=$(run_tool write_file '{"file_path":"linked.txt","content":"linked"}')
assert_equal $'@@ -1 +1 @@\n-replaced\n+linked\n\\ No newline at end of file' "$output"
[[ -L "$tmp/linked.txt" && -x "$tmp/created.txt" ]]
assert_equal linked "$(<$tmp/created.txt)"
mkdir -p "$tmp/folder"
assert_equal 'write_file: folder is a directory' \
  "$(run_tool write_file '{"file_path":"folder","content":"x"}' || true)"

# Empty files and trailing newlines survive creation and replacement.
assert_equal '' "$(run_tool write_file '{"file_path":"new-empty.txt","content":""}')"
[[ -f $tmp/new-empty.txt && ! -s $tmp/new-empty.txt ]]
assert_equal 'write_file: new-empty.txt is already up to date' \
  "$(run_tool write_file '{"file_path":"new-empty.txt","content":""}')"
run_tool write_file '{"file_path":"nested/parent/file.txt","content":"one\n\n"}' >/dev/null
printf 'one\n\n' >"$tmp/expected"
cmp -s "$tmp/expected" "$tmp/nested/parent/file.txt"
run_tool edit_file '{"file_path":"nested/parent/file.txt","old_string":"one","new_string":"two"}' >/dev/null
printf 'two\n\n' >"$tmp/expected"
cmp -s "$tmp/expected" "$tmp/nested/parent/file.txt"

# A rejected binary target is unchanged by either tool.
cp "$tmp/blob.bin" "$tmp/before.bin"
typeset tool input
integer exit_code
for tool in edit_file write_file; do
  if [[ $tool == edit_file ]]; then
    input='{"file_path":"blob.bin","old_string":"GIF","new_string":"x"}'
  else
    input='{"file_path":"blob.bin","content":"x"}'
  fi
  exit_code=0
  output=$(run_tool "$tool" "$input") || exit_code=$?
  assert_equal 2 "$exit_code"
  assert_equal "$tool: blob.bin is not a text file" "$output"
  cmp -s "$tmp/before.bin" "$tmp/blob.bin"
done

# Diff failures retain the write but clean up its temporary files.
mkdir "$tmp/fail-bin" "$tmp/scratch"
printf '#!/bin/sh\nexit 2\n' >"$tmp/fail-bin/git"
chmod +x "$tmp/fail-bin/git"
for tool in edit_file write_file; do
  print -rn -- old >"$tmp/fail.txt"
  if [[ $tool == edit_file ]]; then
    input='{"file_path":"fail.txt","old_string":"old","new_string":"new"}'
  else
    input='{"file_path":"fail.txt","content":"new"}'
  fi
  exit_code=0
  output=$(PATH="$tmp/fail-bin:$PATH" TMPDIR="$tmp/scratch" run_tool "$tool" "$input") || exit_code=$?
  assert_equal 2 "$exit_code"
  assert_equal "$tool: cannot render diff for fail.txt" "$output"
  assert_equal new "$(<"$tmp/fail.txt")"
  [[ -z $(find "$tmp/scratch" -mindepth 1 -print -quit) ]] || fail "$tool leaked temporary files"
done

# File changes show their complete diff.
sf_test_frozen_profile
mkdir "$tmp/copied"
cp "$tools/base.fence.jsonc" "$tmp/copied/"
for tool in edit_file write_file; do
  jq -e '.user_preview_lines == "full"' "$tools/$tool/manifest.json" >/dev/null ||
    fail "$tool lost its full preview"
  cp -R "$tools/$tool" "$tmp/copied/"
  SF_TEST_PROFILE=$(jq -c --arg tool "$tmp/copied/$tool" \
    '.tools=[$tool] | .sandbox.enabled=true' <<<"$SF_TEST_PROFILE")
  sf_test_session "$tmp/$tool.jsonl"
  SF_TEST_PROVIDER_TOOL_BYPASS=false \
    sf_test_run "${tool%_file}" "$tmp/$tool.jsonl" >"$tmp/$tool.stream"
  jq -eRn '[inputs | fromjson | select(.type == "tool_result")] |
    length == 1 and .[0].exit_code == 0 and (.[0].model_text | startswith("@@"))' \
    <"$tmp/$tool.stream" >/dev/null || fail "copied sandboxed $tool failed"
done

# Every bundled tool runs, and a sandboxed one carries its own policy.
for tool in "$tools"/*(/); do
  [[ -f $tool/run && -x $tool/run ]] || fail "${tool:t} has no executable run"
  ! jq -e '.sandbox == true' "$tool/manifest.json" >/dev/null ||
    [[ -f $tool/fence.jsonc ]] || fail "${tool:t} is sandboxed without a policy"
done

# Every sandboxed tool has common protections and tool-specific access.
typeset policy resolved settings override
mkdir -p "$tmp/policies"
cp "$tools/base.fence.jsonc" "$tmp/policies/"
for policy in "$tools"/*/fence.jsonc; do
  mkdir -p "$tmp/policies/${policy:h:t}"
  cp "$policy" "$tmp/policies/${policy:h:t}/"
done
for policy in "$tmp"/policies/*/fence.jsonc; do
  settings=$policy
  resolved=$(fence config show --settings "$settings" 2>/dev/null) ||
    fail "${policy:h:t} has an invalid sandbox policy"
  jq -e --arg tool "${policy:h:t}" '
    ["**/.env", "**/.env.*", "**/*.key", "**/*.pem", "**/*.p12", "**/*.pfx",
     "**/.direnv/**", "**/.git-credentials", "**/.netrc", "**/.npmrc", "**/.pypirc",
     "~/.*hist*", "~/.aws/**",
     "~/.cache/huggingface/token", "~/.cargo/credentials.toml",
     "~/.claude/.credentials.json", "~/.claude/oauth-token",
     "~/.codex/.credentials.json", "~/.codex/auth.json",
     "~/.config/colima/_lima/_config/**", "~/.config/gh/hosts.yml",
     "~/.config/git/credentials", "~/.config/glab-cli/config.yml", "~/.config/op/**",
     "~/.config/pnpm/auth.ini", "~/.config/pnpm/rc", "~/.config/rclone/rclone.conf",
     "~/.docker/config.json", "~/.git-credentials", "~/.gnupg/**", "~/.netrc",
     "~/.npmrc", "~/.ssh/**", "~/.viminfo", "~/.vimtmp/**", "~/.zsh_sessions/**"] as $read |
    ["**/.env", "**/.env.*", "**/.direnv/**", "**/.netrc",
     "**/.git-credentials", "**/.npmrc", "**/.pypirc",
     "**/*.key", "**/*.pem", "**/*.p12", "**/*.pfx"] as $write |
    ($tool | IN("fetch_url", "search_web")) as $web |
    ($tool | IN("shell", "shell_readonly")) as $shell |
    .filesystem.defaultDenyRead == true and
    .filesystem.denyRead == $read and
    .filesystem.denyWrite == ($write + ["**/.shellfish", "**/.shellfish/**"] +
      if $tool == "shell_readonly" then ["**"] else [] end) and
    (.filesystem.allowRead // []) == (if $web then [] else ["."] end) and
    (.filesystem.allowWrite // []) == (if $web or $tool == "read_file" then [] else ["."] end) and
    (.filesystem.allowExecute // []) == (if $shell then ["."] else [] end) and
    (.allowPty // false) == $shell and
    (.network.allowedDomains // []) ==
      (if $tool == "fetch_url" then ["r.jina.ai"]
       elif $tool == "search_web" then ["mcp.exa.ai"] else [] end) and
    .network.allowLocalBinding != true and .network.allowLocalOutbound != true and
    .command.useDefaults == true
  ' <<<"$resolved" >/dev/null || fail "${policy:h:t} has unexpected sandbox permissions"

  # Profile additions survive the tool's relative inheritance chain.
  override="$tmp/${policy:h:t}-override.json"
  jq -n --arg policy "$policy" '{extends:$policy,
    filesystem:{allowRead:["/extra/read"],allowWrite:["/extra/write"]},
    network:{allowedDomains:["extra.test"]}}' >"$override"
  fence config show --settings "$override" 2>/dev/null |
    jq -e --argjson base "$resolved" '
      .filesystem.allowRead == (($base.filesystem.allowRead // []) + ["/extra/read"]) and
      .filesystem.allowWrite == (($base.filesystem.allowWrite // []) + ["/extra/write"]) and
      .filesystem.denyRead == $base.filesystem.denyRead and
      .filesystem.denyWrite == $base.filesystem.denyWrite and
      .network.allowedDomains == (($base.network.allowedDomains // []) + ["extra.test"])
    ' >/dev/null || fail "${policy:h:t} lost sandbox overrides or base protections"
done
