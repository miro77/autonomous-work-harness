# Single-Tick Prompt (fresh context per slice)

One tick = one unit of migration work, run in a session that starts empty and
ends when the tick is checkpointed. Model quality degrades as a session's
context fills, so this mode buys every slice the model's best regime: a tick
reads everything it needs from disk and writes everything the next tick needs
back to disk — nothing survives in conversation, by design.

Drive it with `migration/tools/kick-loop.sh --drive` (back-to-back
fresh-context ticks until termination — the recommended unattended mode) or
`kick-loop.sh --tick` for a single one. [LOOP-PROMPT.md](LOOP-PROMPT.md) reuses
this same tick definition inside one self-paced session. Scheduling recipes:
[RESUMING.md](RESUMING.md).

---

Advance the <LEGACY> → <TARGET> migration by exactly ONE tick, then end the
session. Read CLAUDE.md and migration/PLAN.md first. You have no memory of
previous ticks: the repo (parity matrix, decisions, worklog, fixtures) is the
only state there is, so anything the next tick must know has to be on disk
before you stop.

FAILURE FEEDBACK — read prior tick's gate failure before starting:
If `.harness/state/last-gate-failure.txt` exists, read it FIRST (`cat
.harness/state/last-gate-failure.txt`). It contains the exact gate failure
output (test failures, lint errors) from the previous tick. Fix the issue it
describes before doing anything else — a retry without addressing it just
burns another tick on the same mistake. The file is cleared when gates pass,
so its presence means the last tick failed its gates. If it does not exist,
the last tick passed (or no tick has run yet) — proceed normally.

WORKING STATE — persist intermediate state that should survive compaction:
For multi-step work, checkpoint intermediate results to the virtual filesystem
so they survive context compaction:
  `echo '<state json>' | bash migration/tools/persist-state.sh <key>`
  `bash migration/tools/read-state.sh <key>`
State lives in `.harness/state/slice-state/` (local, not committed). Use it
for working memory — the parity matrix and HANDOFF.md are for committed state.
The PreCompact hook reminds you to flush; this gives you the place to flush TO.

TICK PROCEDURE — exactly one unit of work:

0. CONCURRENT-WRITER CHECK — before touching anything.
   Confirm nothing else is writing this tree: `git log`, `git status`, and the
   driver lock (`.harness/kick-loop.lock`).

   ⚠️ A MOVING HEAD IS NOT THE SIGNAL, AND IT IS NOT EVEN THE LIKELY ONE. The
   realistic second writer never commits — it mutates the WORKING TREE. This
   has really happened: a live session and an ORPHANED tick (a `claude -p`
   child that outlived the driver that spawned it) both wrote the same tree.
   The orphan created scratch files, `git restore`d the tick's uncommitted
   matrix claim, and wrote an `audited-pass` status for code no auditor had
   ever seen.

   So ALSO snapshot the scoped tree at the start
   (`bash migration/tools/working-tree-hash.sh`) and RE-CHECK IT BEFORE YOU
   COMMIT. If files you did not touch have appeared, vanished, or reverted,
   you are not alone in the tree:
     - commit what you have with an HONEST status,
     - write HANDOFF.md saying who else is writing,
     - stop.
   NEVER spawn a subagent into a contested tree: a `git checkout` from the
   other writer destroys uncommitted work while the subagent is mid-run.

   A dirty tree you did not create is ALSO this signal — do not "clean it up".
   Read it first. Reverting a fixture generator orphans the fixtures it
   produced: they become unreproducible, and that is not recoverable from the
   tree alone.

1. Read HARNESS_PROFILE from migration/harness.env (default: migration). It
   selects the status board and slice command — migration:
   migration/parity-matrix.md + /migrate-slice; feature:
   migration/spec-matrix.md + /feature-slice. If the bootstrap row (B01 on
   the parity matrix; S00 on the spec matrix) is not audited-pass, execute
   Phase 0 of migration/PLAN.md — that is the whole tick.
2. Otherwise run the profile's slice command (it picks the next row itself:
   unfinished rows first, then the first open row with satisfied
   dependencies).
3. Gates and audit are part of the slice command; never mark a row
   audited-pass without a fresh-context audit and a recorded gates run.

   ⚠️ ORDER MATTERS, NOT JUST THE FACTS. NEVER WRITE `audited-pass` INTO A ROW
   BEFORE THE FRESH-CONTEXT AUDITOR HAS ACTUALLY RUN AND RETURNED. Not "gates
   are green and I'm confident". Not "I ran my own mutation tests". Not "the
   evidence cell says audit pending". The STATUS FIELD is the one thing
   downstream ticks trust WITHOUT re-checking, so writing it early is a
   FABRICATED CLAIM — even if the audit later agrees, which is luck, not
   process. If it had disagreed, the matrix would contain a lie. Gates are not
   an audit. Self-run mutation evidence is not an audit.

3b. A ROW'S "GATED ON X" NOTE IS A CLAIM, NOT EVIDENCE — AND THESE NOTES ROT.
   They were written before X landed. On a real migration, THREE separate rows
   were found gated on runtime that had been ported long ago; one row was not
   blocked at all. Before you skip a row as blocked, GREP FOR X AND CONFIRM IT
   IS STILL MISSING. A stale gate note is the single biggest source of a false
   "nothing is actionable" — and a loop that believes it will write HANDOFF.md
   and stop while dozens of slices are actually ready.
4. If the selected row is blocked on a PENDING decision in
   migration/decisions.md, apply the recorded default assumption if one
   exists. Otherwise record the block in its matrix row and end the tick —
   /migrate-slice stops on blocked rows by design, and the next tick selects
   a different row. Never start a second row within this tick.

AUTONOMY — a tick must finish without a human. It runs unattended, so:

-   Never end a tick by asking the user a question. If a choice is needed that
    CLAUDE.md / PLAN.md / decisions.md does not settle, take the most defensible
    option, record it in migration/decisions.md as `status: assumed` with a
    one-line rationale (a wrong assumption is auditable next tick; a stalled tick
    is invisible), and proceed.
-   Never block on an interactive command. Build/run/test commands run
    non-interactively — capture output to a file and read it back; do not leave a
    command waiting at a foreground prompt. A command that prompts for approval
    every tick is a permissions gap to fix in `.claude/settings.json`
    (`permissions.allow`), not something to wait on.

IDLE TRACKING — cross-tick memory lives in `.harness/state/idle-ticks`:
if this tick advanced work (a matrix row changed status or was split, or
bootstrap progressed), delete that file if it exists. If you found nothing
actionable, increment the integer in it (create it with `1`).

If a slice discovers that a LOCKED gate must change (e.g. a missing
consumer-build check), you cannot edit it — record the exact proposed edit in
migration/PROPOSED-GATE-CHANGES.md (not locked), run the check by hand meanwhile,
and note in the affected matrix rows that the gate is proposed-but-not-wired.
Never route around the lock.

TERMINATION requires BOTH axes clear — fidelity AND reachability:
(a) every matrix row is audited-pass, audited-fail, or blocked-on-human-decision,
AND (b) migration/integration-ledger.md has no open rows — every row is `wired`
or `blocked` (a recorded human decision). Matrix-row state alone is NOT done: a
feature can be audited-pass yet unreachable in the running app, and the ledger is
where that shows. If (a) is met but (b) is not, the migration is NOT done and a
wiring slice is missing — add the wiring row(s) to the matrix (each open ledger
row's `closes-in`) and continue; do not write HANDOFF yet. (The idle-ticks == 2
backstop still forces a stop to avoid a spin; if it fires with open ledger rows,
HANDOFF must list them as the reason work remains.)

When both axes are clear (or the idle backstop fires), write migration/HANDOFF.md
whose FIRST LINE is its machine-readable terminal state:
`STATUS: COMPLETE` (every row audited-pass, ledger fully wired, NO open
PROPOSED-GATE-CHANGES entries), `STATUS: BLOCKED` (blocked rows, blocked
ledger rows, open gate proposals, or OPEN ledger rows the idle backstop left
behind remain — any of these CAPS the state at BLOCKED, never claim COMPLETE
past one), or `STATUS: FAILED` (audited-fail rows remain). Below that line, summarize all audited-fail rows, open
integration-ledger rows, pending decisions, and open PROPOSED-GATE-CHANGES
entries. Run `bash migration/tools/gates.sh`, commit it
(`migrate HANDOFF: done`), then verify the claim with
`bash migration/tools/check-complete.sh` — if it rejects the record, fix and
re-commit: the driver refuses an invalid handoff.
If gates cannot pass because audited-fail rows remain, commit with a subject
containing `audited-fail` (e.g. `migrate HANDOFF: audited-fail rows remain`)
so the recorded-checkpoint escape covers the stop.

STOP: one tick only. Report the slice id, status, and risks, then end the
session — never claim or start a second row, and do not schedule anything
yourself. The driver starts the next tick in a fresh session.
