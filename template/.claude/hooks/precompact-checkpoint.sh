#!/usr/bin/env bash
# PreCompact hook: the conversation is about to be summarized (context is full).
# Do NOT block — blocking only defers compaction and can wedge an unattended loop.
# Instead inject a reminder to flush the current slice to disk and re-anchor on
# the load-bearing rules, so nothing in-flight is lost when the message history
# is compacted. The harness resumes from disk, so the on-disk checkpoint is what
# matters, not this conversation.
#
# Also appends a line to .harness/compaction.log so a later "did compaction drop
# something?" question has an audit trail. Fail-open: never wedge the session.
set -uo pipefail

input=$(cat)
trig=$(printf '%s' "$input" | tr '\n\r' '  ' \
  | sed -n 's/.*"trigger"[[:space:]]*:[[:space:]]*"\([a-zA-Z]*\)".*/\1/p')
[ -n "$trig" ] || trig="auto"

# Best-effort audit log (excluded from the gate hash; harmless if it fails).
# cd into the repo root and write a RELATIVE path — an absolute Windows path
# ("C:/...") from `git rev-parse --show-toplevel` can trip MSYS mkdir on Git Bash.
if root=$(git rev-parse --show-toplevel 2>/dev/null) && cd "$root" 2>/dev/null; then
  mkdir -p .harness 2>/dev/null \
    && printf '%s precompact trigger=%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo now)" "$trig" \
       >> .harness/compaction.log 2>/dev/null || true
fi

# Reminder injected into the post-compaction context. Pure ASCII, no quotes, so
# it embeds directly in the JSON string without escaping.
msg="Context compaction is starting (trigger: ${trig}). Before proceeding, flush the current slice to disk so nothing in-flight is lost: update the migration/parity-matrix.md row status, append progress to a worklog or migration/HANDOFF.md, and commit at a slice boundary. The harness resumes from disk, not from this conversation, so anything not written down is at risk. Re-anchor on the CLAUDE.md hard rules: no success claim without a passing migration/tools/gates.sh run recorded for the exact tree; one slice per pass; preserve legacy behavior except recorded deviations."

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":"'"$msg"'"}}'
exit 0
