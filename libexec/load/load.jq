include "lib/runtime";
include "lib/session";

# A durable session always ends at a newline; a fragment after the last one is
# an interrupted append that no reader may interpret.
def durable_prefix:
  if endswith("\n") then .
  else
    rindex("\n") as $end |
    if $end == null then "" else .[0:($end + 1)] end
  end;

durable_prefix | split("\n") | map(select(length > 0) | fromjson) |
if length < 1 or (.[0] | canonical_session_header(1) | not) then
  error("invalid session header")
else
  # Loading validates the whole durable prefix before emitting any of it.
  (.[1:] | session_load) as $validated |
  ({type:"_session_load", path:$path} | tojson), "\n",
  (.[] | tojson, "\n")
end
