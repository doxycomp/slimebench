# shellcheck shell=bash
#
# One row of structured output, alongside the human-readable text.
#
# The four phases driven by shell scripts -- barriers, garbage collection, the
# JVM ramp, .NET ahead-of-time -- wrote column-aligned text and nothing else.
# Their tables in docs/RESULTS.md were therefore transcribed by hand, drifted
# every time a series was replaced, and nothing noticed. The text is still the
# thing a person reads; this is the thing bench/tables.py reads.
#
# Usage, after setting JSONL to a path:
#
#   jrow table=gc lang=go collections=1 gc_ms=0.57
#
# Keys are taken literally. Values that parse as numbers become JSON numbers,
# everything else becomes a string, and a value containing `=` keeps it (only
# the first `=` separates). A row with no JSONL set is silently dropped, so a
# script still works when run by hand.

jrow() {
  [ -n "${JSONL:-}" ] || return 0
  python3 -c '
import json, sys
row = {}
for arg in sys.argv[1:]:
    k, _, v = arg.partition("=")
    if not k:
        continue
    try:
        row[k] = int(v)
    except ValueError:
        try:
            row[k] = float(v)
        except ValueError:
            row[k] = v
print(json.dumps(row))
' "$@" >> "$JSONL"
}

# Derive the JSONL path from the text output path and start it empty, so a
# re-run does not append to the previous one.
jsonl_for() {
  JSONL="${1%.txt}.jsonl"
  : > "$JSONL"
  export JSONL
}
