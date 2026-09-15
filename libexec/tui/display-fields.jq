def compact_tokens:
  if . < 1000 then tostring
  elif . < 10000 then
    (((. / 100 | round) / 10) | tostring | sub("\\.0$"; "")) + "k"
  elif . < 999500 then ((. / 1000 | round) | tostring) + "k"
  elif . < 10000000 then
    (((. / 100000 | round) / 10) | tostring | sub("\\.0$"; "")) + "m"
  else ((. / 1000000 | round) | tostring) + "m"
  end;

def turn_usage_fields($context_window):
  ["turn_usage",
   ((.input_tokens | compact_tokens) + " ↑" +
     (if has("cached_tokens") and .input_tokens > 0 then
        " " + ((.cached_tokens * 100 / .input_tokens) | round | tostring) + "% ⦿"
      else "" end) + " " + (.output_tokens | compact_tokens) + " ↓" +
     (if $context_window != null then
        " " + ((.input_tokens * 100 / $context_window) | round | tostring) +
        "% of " + ($context_window | compact_tokens) + " ◔"
      else "" end)),
   (if has("reasoning_tokens") then (.reasoning_tokens | tostring) else "" end)];

# Context feeds the model and is reference material worth clamping; a notice
# speaks only to the reader, so it is shown whole.
def hook_display_class:
  if (.model_text // "") == "" then "notice" else "context" end;

def display_nul_safe:
  gsub("\u0000"; "�");

def display_summary:
  map(select(. != null) |
      gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "") |
      select(. != "")) |
  join(" · ");

# Emit fixed-width, NUL-delimited event fields.
def emit_display_batch:
  (.[], ["batch_ok"]) |
  if length < 1 or length > 7 or any(.[]; type != "string") then
    error("invalid display fields")
  else (. + ["", "", "", "", "", ""])[0:7][] | display_nul_safe, "\u0000" end;

def durable_display_fields:
  .replay as $replay |
  .record |
  if .type == "system" and $replay then
    ["system", .content]
  elif .type == "error" then
    (.user_text | split("\n")) as $lines |
    ["error", $lines[0], ($lines[1:] | join("\n")), "end"]
  elif .type == "user" then
    if $replay then ["user", .content[0].text] else empty end
  elif .type == "assistant" then
    if $replay then
      . as $message |
      (.content | to_entries) as $content |
      ([$content[] | select(.value.type == "reasoning" and
        (.value.text | test("[^\\n]"))) | .key]) as $reasoning |
      ["assistant_start"],
      ($content[] |
        if .value.type == "text" then
          ["assistant_message_delta", (.key | tostring), .value.text]
        else
          ["assistant_reasoning_delta", (.key | tostring), .value.text] +
          (if ($reasoning | length) == 1 and .key == $reasoning[0] and
              $message.usage.reasoning_tokens? != null
           then [($message.usage.reasoning_tokens | tostring)] else [] end)
        end),
      ["assistant_end"]
    else empty end
  else
    empty
  end;
