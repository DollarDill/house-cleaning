# ADR-0001: Propose-only deletion, forced human approval, and a durable audit ledger

**Status:** Accepted
**Date:** 2026-07-18

## Context

v1 of house-cleaning ran the deletion test as an auto-apply pipeline: the skill deleted a
candidate unit — a file, a region, a line — then reran the project's own oracle (build +
typecheck + tests) and committed the deletion straight to a `house-cleaning/<date>` branch
whenever the oracle came back green and the candidate sat in a HIGH-confidence,
oracle-verified, coverage-backed tier. Only candidates that were judgment-laden or
security-shaped stopped short of auto-commit and surfaced as proposals instead.

That tiering rested on a premise that doesn't hold in general: a green oracle after deletion
is evidence that nothing observable changed, not proof that nothing changed. It's the same
problem mutation-testing research calls the equivalent-mutant problem: a mutant (here, a
deletion) can survive every test in the suite while still altering behavior the suite never
exercised, or removing code a human reviewer would recognize as intentional even though
nothing currently calls it. "Tests still pass" tells you the oracle didn't object; it doesn't
tell you the deletion was safe. v1's HIGH tier treated the first as if it were the second, and
auto-committed on that basis.

house-cleaning is also, by design, a tool whose job is to remove code from a repository other
people depend on. The cost of a wrong deletion landing silently on a branch someone might
merge is asymmetric with the cost of a wrong proposal a human declines. That asymmetry is why
v2 revisits the tiering decision instead of just extending the oracle-verified tier further.

## Decision

v2 removes tiered auto-apply. Every deletion candidate, regardless of confidence tier or
evidence strength, goes through the same two-stage contract:

1. **Probe.** The deletion test deletes the candidate, runs the oracle, and always reverts,
   win or lose. A probe's only output is a logged verdict (`provably-dead`, oracle-blind, etc.)
   plus a coverage record; it never commits and never leaves the working tree changed. This
   holds even for the units that would have auto-applied under v1's HIGH tier.
2. **Propose, approve, apply.** Nothing is deleted for real until a human reviews a
   confidence-grouped, evidence-forward proposal list and explicitly approves it in that turn.
   Approval is a forced procedural step, not a record the agent can author on its own:
   `cull.sh apply` runs only the human-authorized manifest, and a `decision:approved` ledger
   entry is an accident-guard cross-check on that manifest, not the enforcement mechanism
   itself. Approved deletions then apply as atomic, oracle-verified commits — one commit per
   unit, each re-verified green before it lands, with a red oracle on an applied unit
   triggering an automatic restore-and-halt.

Alongside the propose-only reversal, v2 adds a durable audit trail: every run writes an
append-only `ledger.jsonl` (unit identifiers, evidence type, and verdicts only, never file
contents, diffs, or deleted code) plus a regenerated `audit.md` projection, both committed on
the working branch and additively persisted onto the base branch so the record survives even a
cleanup that never merges. The ledger's JSONL format makes `jq` a required dependency going
forward. Probing itself is now scale-first and coarse-to-fine: batch delta-debugging before
descending to region, bisect, then word granularity, with coverage tracked and resumable
across runs instead of assumed complete after one pass.

## Rationale

For a tool whose primary action is destructive, control and auditability matter more than
throughput. Two independent design choices follow from that:

- **The oracle stays the strongest verification tier, but stops being sufficient on its own.**
  It's external-signal, rules-based feedback rather than same-model self-judgment, which is
  exactly why v1 trusted it enough to auto-apply in the first place; that trust was
  well-placed as far as it went. Human approval adds a second layer whose failure mode doesn't
  correlate with the oracle's — a human catches paths the test suite never exercised, in a way
  a green oracle structurally cannot. Two independent layers catch more than one layer run
  twice.
- **A durable, committed ledger makes every decision reviewable after the fact, not just at
  the moment it was made.** v1's `.house-cleaning/` scratch directory and `CULLING.md` were
  gitignored and disposable; a team member joining a cleanup mid-flight, or auditing one after
  the fact, had nothing but the commit log to go on. Persisting the ledger to the base branch
  means the audit trail is team-visible and versioned even when the deletions themselves live
  on a branch that never merges.

## Consequences

**Accepted trade-off: rubber-stamping.** A propose-only model that surfaces every candidate as
a flat list invites exactly the failure mode it's meant to prevent: a human skimming past
forty proposals and clicking "approve all" is barely different from v1's auto-apply, and
arguably worse because it looks reviewed when it wasn't. v2 mitigates this by grouping
proposals by confidence rather than presenting them uniformly — oracle-verified, provably-dead
candidates are eligible for an informed bulk-approve (the human sees the evidence class, not
just a count), judgment-laden and oracle-blind candidates require per-item or small-group
review, and security- or secret-shaped candidates are never bulk-approvable under any
grouping. The mitigation is procedural, not automatic: it depends on the proposal UI staying
evidence-forward rather than degrading into a checkbox list, which is why this is flagged as an
ongoing signal to watch (via the Phase-2 lift/adherence eval) rather than a solved problem.

**Rejected alternative: keep auto-apply for the trivially-safe subset, propose the rest.** A
middle ground was on the table: narrow v1's HIGH tier down to only the deletions with the
strongest possible evidence (say, dead files with zero references anywhere, confirmed dead
across a whole coverage sweep) and auto-apply just those, proposing everything else. This was
rejected because it still auto-commits without a human in the loop on a destructive tool, and
the equivalent-mutant caveat doesn't have a confidence threshold below which it stops applying;
a narrower auto-apply tier is a smaller version of the same risk, not a different one. The
user's stated preference was full control and a complete audit trail over any amount of
throughput, which a propose-only model satisfies unconditionally and a narrowed auto-apply
tier does not.

**Other consequences:**
- The `.house-cleaning/` ledger is committed history by default, so JSONL merge churn on large
  incremental cleans is a live risk rather than a hypothetical one. The storage seam is a
  single decision point (a tracking-policy constant), so flipping to a local, gitignored
  ledger if churn bites is a one-line change, not a rewrite.
- `jq` moves from unused to required. This is a breaking change for any install that predates
  it (see CHANGELOG 0.2.0); the scripts refuse immediately rather than degrade silently if it's
  missing.
- Throughput drops. Every deletion that would have auto-applied under v1 now waits on a human
  turn. v2 treats this as the cost of running a destructive tool safely, not a regression to
  fix.
