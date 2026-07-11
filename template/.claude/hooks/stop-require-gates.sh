#!/usr/bin/env bash
# Stop hook: no success claim without executable proof.
# Blocks ending the turn unless the migration-relevant tree CONTENT matches a
# recorded successful gates run. Because the proof is content-addressed (see
# working-tree-hash.sh), un-gated changes are caught whether they sit in the
# working tree OR are already committed — a commit does not launder them, and
# deleting a scoped path (even the only one) does not launder it either.
#
# Absence of a proof is treated as UNPROVEN, not as a free pass. The one
# exception is an explicitly recorded non-pass checkpoint (audited-fail / a row
# split) committed to a clean tree — legitimate stopping points, visible in git.
#
# Failure policy: fail-OPEN on environment (not a git repo, no harness.env, no
# scope configured) — there is nothing to protect. But fail-CLOSED if the hash
# TOOL itself is missing/broken, because a broken hash tool is exactly how an
# agent would launder un-gated changes; a broken tool must stop the loop, not
# free it. This stays anti-wedge: Claude Code re-invokes with
# stop_hook_active=true on the retry (handled first below), so any block is a
# single challenge, not a hard lock.
set -uo pipefail

input=$(cat)
# loop protection: if we already challenged once this stop, allow it through.
case "$input" in
  *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;;
esac

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f migration/harness.env ] || exit 0

# shellcheck source=/dev/null
source migration/harness.env
read -r -a SCOPE <<< "${HARNESS_SCOPE:-}"
# Nothing is CONFIGURED in scope → nothing to protect, ever.
[ "${#SCOPE[@]}" -gt 0 ] || exit 0

# Paths that currently exist (used for the cleanliness check only). The content
# hash handles deletions itself, so its correctness does not depend on this.
PATHS=()
for p in "${SCOPE[@]}"; do [ -e "$p" ] && PATHS+=("$p"); done

current=$(bash migration/tools/working-tree-hash.sh 2>/dev/null); rc=$?
state=.harness/state/gates-passed.diffsha

# Fail-CLOSED if the hash tool errored or produced nothing: without a hash we
# cannot verify the proof, and a silently-broken tool would otherwise be a free
# pass. Challenge once; the stop_hook_active retry above releases it, so a
# genuinely broken tool never hard-locks the session.
if [ "$rc" -ne 0 ] || [ -z "$current" ]; then
  cat >&2 <<'MSG'
The harness content-hash tool (migration/tools/working-tree-hash.sh) produced no
hash — it is missing, erroring, or was modified. The gate proof cannot be
verified, so this turn is held. Restore the tool (e.g. git checkout) and run:
  bash migration/tools/gates.sh
MSG
  exit 2
fi

# A matching proof allows the stop — survives commits, and holds even if every
# scoped path was deleted (the hash then differs from the proof, so this only
# passes when the deletion itself was gated).
if [ -f "$state" ] && [ "$current" = "$(cat "$state")" ]; then exit 0; fi

# No proof yet AND nothing currently in scope. Safe to allow ONLY if the scope
# was never committed either — otherwise this is an un-gated deletion of
# previously-tracked content (a scoped root removed and committed) and must be
# challenged. `git log` on the scope pathspec still sees a path's history after
# it has been deleted, so a committed deletion is caught here.
if [ ! -f "$state" ] && [ "${#PATHS[@]}" -eq 0 ] \
   && [ -z "$(git log -1 --format=%H -- "${SCOPE[@]}" 2>/dev/null)" ]; then
  exit 0
fi

# Escape hatch: a recorded non-pass checkpoint on a clean (fully committed)
# tree is a legitimate stop. Exclude .harness from the cleanliness check so an
# untracked proof file (e.g. HARNESS_SCOPE=".") doesn't read as "dirty". Markers
# match the /migrate-slice commit conventions; edit to taste. Deliberate and
# git-visible, not a silent bypass.
if [ "${#PATHS[@]}" -gt 0 ]; then
  dirty=$(git status --porcelain --untracked-files=all -- "${PATHS[@]}" ':(exclude).harness' 2>/dev/null)
else
  dirty=$(git status --porcelain --untracked-files=all -- . ':(exclude).harness' 2>/dev/null)
fi
if [ -z "$dirty" ]; then
  subject=$(git log -1 --format=%s 2>/dev/null || true)
  case "$subject" in
    *audited-fail*|*"split into sub-slices"*) exit 0 ;;
  esac
fi

cat >&2 <<'MSG'
Migration content is not covered by a successful gates run for this exact tree
state (this includes changes you have already committed, deletions of scoped
paths, and the case where no proof exists yet). Run:
  bash migration/tools/gates.sh
Fix any failures, update migration/parity-matrix.md, then finish. If this is a
deliberately recorded audited-fail or row-split checkpoint, commit it (clean
tree, matching subject) and it will be allowed.
MSG
exit 2
