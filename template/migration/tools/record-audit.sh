#!/usr/bin/env bash
# Record a fresh-context audit verdict. Called by the parity-auditor /
# spec-auditor subagent as the LAST thing it does, once it has actually finished
# reading the code:
#
#   bash migration/tools/record-audit.sh <row-id> pass|fail
#
# The record is bound to the audit-hash of the code the auditor read (see
# audit-hash.sh). check-audits.sh, running inside gates.sh, then refuses to let a
# row be marked `audited-pass` on the board unless a matching record exists — so
# "the auditor said it is fine" stops being a sentence the model can simply type.
#
# THE FAILURE THIS EXISTS FOR (observed on a live migration): the tick wrote
# `audited-pass` into the matrix BEFORE the auditor had returned — not out of
# malice, but because gates were green and it felt done. The status field is the
# one thing downstream ticks trust without re-checking, so an early write is a
# fabricated claim even when the audit later agrees.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

row="${1:-}"
verdict="${2:-}"

if [ -z "$row" ] || [ -z "$verdict" ]; then
  echo "usage: record-audit.sh <row-id> pass|fail" >&2
  exit 2
fi
case "$verdict" in
  pass|fail) ;;
  *) echo "record-audit: verdict must be 'pass' or 'fail' (got '$verdict')" >&2; exit 2 ;;
esac
# Row ids are matrix cells, not paths — keep them boring so they cannot escape
# the audits directory.
case "$row" in
  *[!A-Za-z0-9._-]*) echo "record-audit: row id '$row' has characters outside [A-Za-z0-9._-]" >&2; exit 2 ;;
esac

hash="$(bash migration/tools/audit-hash.sh)" || {
  echo "record-audit: could not compute the audit hash — refusing to record" >&2
  exit 1
}
[ -n "$hash" ] || { echo "record-audit: empty audit hash — refusing to record" >&2; exit 1; }

mkdir -p .harness/state/audits
printf '%s %s\n' "$hash" "$verdict" > ".harness/state/audits/$row"
echo "record-audit: $row -> $verdict (code $hash)"
