# Changelog

All notable changes to house-cleaning will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

See the forthcoming ADR (auto-apply → propose-only reversal) for the full
context and trade-off record.
