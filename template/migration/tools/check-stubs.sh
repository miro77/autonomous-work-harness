#!/usr/bin/env bash
# Stub-sentinel gate: every runtime stub in shipped source must be registered in
# migration/integration-ledger.md. A "stub" is any occurrence of STUB_SENTINEL —
# a "not implemented"/placeholder marker the user can hit. The contract: each
# sentinel hit must carry its ledger id as an `INTEG-<id>` tag on the same line,
# and that id must appear in the ledger table. This turns silent stub
# accumulation into a gate failure — you cannot ship an unreachable/placeholder
# path without recording it, so the aggregate stays visible instead of hiding
# behind a placeholder string until a human launches the app.
#
# OPT-IN: does nothing until STUB_SENTINEL is set in migration/harness.env.
#   STUB_SENTINEL — extended-regex matching your runtime placeholder string
#                   (e.g. 'not yet implemented' or 'UnimplementedError').
#   STUB_SCAN     — space-separated shipped-source paths to scan (NOT tests);
#                   required when STUB_SENTINEL is set.
#
# Read-only. Needs bash + git + grep. No `set -o pipefail` (grep -q closes pipes
# early, which pipefail would misread — same reason as check-docs.sh).
set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "stub-check: not a git repository"; exit 1; }

# shellcheck source=/dev/null
[ -f migration/harness.env ] && source migration/harness.env

SENTINEL="${STUB_SENTINEL:-}"
if [ -z "$SENTINEL" ]; then
  echo "stub-check: disabled (STUB_SENTINEL unset in migration/harness.env)"
  exit 0
fi

read -r -a SCAN <<< "${STUB_SCAN:-}"
if [ "${#SCAN[@]}" -eq 0 ]; then
  echo "stub-check: STUB_SENTINEL is set but STUB_SCAN is empty — set STUB_SCAN to your shipped source paths in migration/harness.env" >&2
  exit 1
fi

ledger=migration/integration-ledger.md

# Files under the scan paths, tracked or untracked-not-ignored (so build dirs,
# node_modules, .harness runtime state are skipped automatically). while-read
# instead of mapfile: stock macOS bash 3.2 has no mapfile, and this runs under
# gates.sh on whatever bash is on PATH.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done \
  < <(git ls-files -co --exclude-standard -- "${SCAN[@]}" 2>/dev/null | sort -u)

# Ledger ids: the INTEG-<id> tokens in the ledger table.
LEDGER_IDS=()
if [ -f "$ledger" ]; then
  while IFS= read -r id; do LEDGER_IDS+=("$id"); done \
    < <(grep -oE 'INTEG-[A-Za-z0-9_.-]+' "$ledger" 2>/dev/null | sort -u)
fi
has_id(){ printf '%s\n' "${LEDGER_IDS[@]:-}" | grep -qxF "$1"; }

fails=0
note(){ printf 'STUB: %s\n' "$1"; fails=$((fails+1)); }

for f in "${FILES[@]:-}"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    n=${hit%%:*}; text=${hit#*:}
    tag=$(printf '%s' "$text" | grep -oE 'INTEG-[A-Za-z0-9_.-]+' | head -n1)
    if [ -z "$tag" ]; then
      note "$f:$n  stub with no INTEG-<id> ledger tag — register it in $ledger and tag this line"
    elif ! has_id "$tag"; then
      note "$f:$n  references $tag, which is not a row in $ledger"
    fi
  done < <(grep -nEI "$SENTINEL" "$f" 2>/dev/null)   # -I: a binary match would emit a garbage note line
done

echo "----------------------------------------"
if [ -z "${FILES[*]:-}" ]; then
  echo "stub-check: no files matched STUB_SCAN (${STUB_SCAN}) — check the paths" >&2
  exit 1
fi
if [ "$fails" -eq 0 ]; then
  echo "stub-check: every shipped stub is registered in $ledger"
else
  echo "stub-check: $fails untracked stub(s) — add each to $ledger (or wire the feature so the stub is gone)"
fi
[ "$fails" -eq 0 ]
