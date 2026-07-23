# Changelog

All notable changes to house-cleaning will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A run should now stay inside the job you asked for.** The skill holds one law —
  `NO PROPOSAL WITHOUT A CANDIDATE RECORD` — so a unit has to be nominated and carried
  through the pipeline before it can reach your approval turn. Tidy-ups invented at
  approval time ("not dead, but an easy win") no longer qualify. Run `/house-cleaning`
  as before; nothing about the stages, scripts, or ledger schema changed.
- **The boundary now names the excuses, not just the rules.** A table of the
  rationalizations that lead past each line — surfacing out-of-scope edits, declining a
  unit without recording it as kept, skipping a probe because the answer seems obvious —
  sits next to the prohibitions, so the excuse is on the page before it gets used.
- **A run can no longer start probing before its oracle is established.** `cull.sh` is
  off-limits until Stage 0 closes, because a probe against an undetected oracle returns
  verdicts indistinguishable from real ones.

### Changed

- **A failed revert no longer costs you the audit trail.** The always-revert rule now
  tells you to restore the probed path only (`git checkout -- <path>`); restoring the
  whole tree would discard ledger records not yet checkpointed. The record-via-ledger
  rule likewise says what to do once you've recorded something by hand.
- `coverage-view --since` is now described accurately: it reports stale coverage, it
  does not re-nominate. Re-nominating resumed units at Stage 1 is yours to do — skipping
  it made the coverage line under-report what was left uncovered.
- The boundary section reads top-down as law → prohibitions → rationalizations
  (heading trimmed to `## The boundary`).

## 0.2.0 — BREAKING

**Tiered auto-apply is removed. The deletion test is now propose-only and
human-approved — no unit is ever deleted without an explicit approval turn.**
If you scripted around v1's behavior of oracle-verified candidates applying
without review, that behavior no longer exists.

### Changed (breaking)

- **Propose-only deletion test.** Every deletion is now a **probe**: delete →
  oracle → **always revert** → log a verdict. Probes never commit and never
  mutate the tree, regardless of outcome — including the units that used to
  auto-apply under v1's tiered model. Nothing is removed for real until a
  human reviews a confidence-grouped, evidence-forward proposal list and
  approves it in that turn; `cull.sh apply` runs only that human-authorized
  manifest.
- **`jq` is now a required dependency.** The ledger is JSONL; `ledger.sh` and
  `cull.sh` both refuse immediately (exit 2) if `jq` is missing. Install `jq`
  before upgrading.

### Added

- **Durable, committed audit/coverage ledger.** Every run writes an
  append-only `.house-cleaning/runs/<run_id>/ledger.jsonl` plus a regenerated
  `audit.md` projection. In the default `committed` storage mode, the ledger
  is checkpointed on the working `house-cleaning/*` branch and additively
  persisted onto the base branch at the final gate, so the audit trail is
  team-visible, versioned, and survives an abandoned cleanup even if the
  deletions themselves never merge. A `local` mode remains available as a
  no-commit, gitignored escape hatch (`HC_LEDGER_MODE=local`).
  Committed mode force-adds its own `.house-cleaning/` ledger, so it still
  works even if a prior v1 run or a prior `local`-mode run left
  `.house-cleaning/` git-ignored in this repo.
  See `skills/house-cleaning/references/ledger-schema.md` for the full record
  schema.
- **No-content security floor, enforced mechanically.** Ledger records may
  carry unit identifiers, evidence type, and oracle verdicts only; `append`
  refuses (recursively, at any nesting depth) any record containing a
  `content`, `diff`, `code`, `body`, or `snippet` key. No file contents or
  deleted code can enter committed history through the audit trail.
- **Scale-first, coarse-to-fine pipeline with incremental coverage.** Probing
  is batch-first (delta-debugging/ddmin over a whole candidate set) before
  descending to region/bisect/line granularity, and coverage is tracked and
  resumable across runs: `ledger.sh coverage-view --since` invalidates
  coverage for anything changed since its recorded commit, and
  `coverage-summary` refuses to report completion while any candidate is
  unswept.
- **Atomic, oracle-verified applied commits.** Each approved deletion lands as
  its own commit, verified green before it lands; a red oracle on an applied
  unit restores it and halts rather than leaving a broken tree committed.
  Untracked deletions are tar-archived before removal.

### Rationale

See [ADR-0001](docs/decisions/ADR-0001-propose-only-deletion-audit.md)
(auto-apply → propose-only reversal) for the full context and trade-off
record.
