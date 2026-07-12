#!/usr/bin/env bash
# Executable completion validator: is a claimed termination actually valid,
# and which TERMINAL STATE is it?
#
#   bash migration/tools/check-complete.sh
#
# Valid   -> prints "STATUS: COMPLETE|BLOCKED|FAILED" (+ a count summary),
#            exit 0.
# Invalid -> prints why, exit 1. (Not a harness repo at all -> exit 2.)
#
# The tick prompt runs this BEFORE committing migration/HANDOFF.md, and
# kick-loop.sh runs it whenever HANDOFF.md exists (at startup and when a
# drive terminates) - so "done" is a machine-checked claim, not a file's
# mere existence. Terminal-state semantics:
#
#   COMPLETE  every status-board row audited-pass, integration ledger fully
#             wired, NO open gate-change proposals. The only state that
#             means "the work is done".
#   BLOCKED   nothing left the loop can do, but human decisions remain:
#             blocked rows, blocked ledger rows, or open ## PROPOSAL entries.
#   FAILED    audited-fail rows remain - implemented work did not pass its
#             audit and a human must look.
#
# HANDOFF.md must exist, be TRACKED and CLEAN (committed - an untracked or
# modified handoff is an end state nobody reviewed), and its FIRST line must
# be "STATUS: <state>" matching what this validator derives from the boards.
#
# Reads HARNESS_PROFILE from harness.env: "feature" validates
# migration/spec-matrix.md, anything else migration/parity-matrix.md.
# Status columns are located BY HEADER NAME, so both board layouts work.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-complete: not a git repository" >&2; exit 2; }
[ -f migration/harness.env ] || { echo "check-complete: no migration/harness.env - is the harness installed?" >&2; exit 2; }
# shellcheck source=/dev/null
source migration/harness.env

fail(){ echo "check-complete: INVALID - $*" >&2; exit 1; }

handoff="migration/HANDOFF.md"
[ -f "$handoff" ] || fail "$handoff does not exist (no termination has been recorded)"
git ls-files --error-unmatch "$handoff" >/dev/null 2>&1 \
  || fail "$handoff is not tracked by git - the termination record is not committed"
[ -z "$(git status --porcelain -- "$handoff" 2>/dev/null)" ] \
  || fail "$handoff has uncommitted modifications - commit the termination record"

claimed="$(head -n 1 "$handoff" | sed -n 's/^STATUS:[[:space:]]*\(COMPLETE\|BLOCKED\|FAILED\)[[:space:]]*$/\1/p')"
[ -n "$claimed" ] \
  || fail "$handoff line 1 must be exactly 'STATUS: COMPLETE|BLOCKED|FAILED' (got: '$(head -n 1 "$handoff")')"

# --- status board ---
if [ "${HARNESS_PROFILE:-migration}" = "feature" ]; then
  board="migration/spec-matrix.md"
else
  board="migration/parity-matrix.md"
fi
[ -f "$board" ] || fail "status board $board not found"

# Count row statuses. awk locates the 'status' column from the header row and
# then classifies every data row (first cell non-empty, not a --- separator).
counts="$(awk -F'|' '
  function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /^\|/ {
    n = split($0, c, "|")
    if (col == 0) {
      for (i = 2; i <= n; i++) if (trim(c[i]) == "status") { col = i; break }
      next
    }
    first = trim(c[2])
    if (first == "" || first ~ /^[-: ]+$/ || first == "...") next
    s = trim(c[col])
    if      (s == "audited-pass")                                        pass++
    else if (s == "audited-fail")                                        failn++
    else if (s == "blocked")                                             blockn++
    else if (s == "open" || s == "in-progress" || s == "split-required") unfinished++
    else                                                                 unknown++
  }
  END { printf "%d %d %d %d %d", pass+0, failn+0, blockn+0, unfinished+0, unknown+0 }
' "$board")"
# shellcheck disable=SC2086
set -- $counts
n_pass=$1; n_fail=$2; n_block=$3; n_unfinished=$4; n_unknown=$5

[ "$n_unknown" -eq 0 ]    || fail "$board has $n_unknown row(s) with an unrecognized status - fix the board first"
[ "$n_unfinished" -eq 0 ] || fail "$board still has $n_unfinished unfinished row(s) (open/in-progress/split-required) - not a terminal state"
[ "$n_pass" -gt 0 ]       || fail "$board has zero audited-pass rows - an empty or untouched board is not a completed effort"

# --- integration ledger (reachability axis) ---
n_ledger_open=0; n_ledger_blocked=0
if [ -f migration/integration-ledger.md ]; then
  lcounts="$(awk -F'|' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^\| *INTEG-/ {
      id = trim($2)
      if (id == "INTEG-example") next
      s = trim($4)
      if (s == "wired") next
      if (s == "blocked") blockn++
      else open++
    }
    END { printf "%d %d", open+0, blockn+0 }
  ' migration/integration-ledger.md)"
  # shellcheck disable=SC2086
  set -- $lcounts
  n_ledger_open=$1; n_ledger_blocked=$2
fi
[ "$n_ledger_open" -eq 0 ] \
  || fail "integration-ledger has $n_ledger_open OPEN row(s) (built-unwired/stub/deferred-impl) - wire them or block them; not a terminal state"

# --- open gate-change proposals ---
n_props=0
if [ -f migration/PROPOSED-GATE-CHANGES.md ]; then
  n_props="$(grep -cE '^## PROPOSAL' migration/PROPOSED-GATE-CHANGES.md 2>/dev/null || true)"
  case "$n_props" in ''|*[!0-9]*) n_props=0 ;; esac
fi

# --- derive the actual terminal state and compare with the claim ---
if [ "$n_fail" -gt 0 ]; then
  actual="FAILED"
elif [ "$n_block" -gt 0 ] || [ "$n_ledger_blocked" -gt 0 ] || [ "$n_props" -gt 0 ]; then
  actual="BLOCKED"
else
  actual="COMPLETE"
fi
[ "$claimed" = "$actual" ] \
  || fail "$handoff claims STATUS: $claimed but the boards say $actual (audited-fail=$n_fail blocked-rows=$n_block ledger-blocked=$n_ledger_blocked open-proposals=$n_props)"

echo "STATUS: $actual"
echo "check-complete: valid terminal state ($board: $n_pass audited-pass, $n_fail audited-fail, $n_block blocked; ledger blocked=$n_ledger_blocked; open proposals=$n_props)"
exit 0
