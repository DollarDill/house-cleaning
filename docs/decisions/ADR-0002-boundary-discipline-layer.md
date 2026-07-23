# ADR-0002: The boundary carries a discipline layer, anchored on candidacy

**Status:** Accepted
**Date:** 2026-07-23

## Context

ADR-0001 established the safety architecture: propose-only, forced human approval, a durable
audit ledger. Those controls are *mechanical* — scripts refuse to apply anything the human
hasn't authorized, and no amount of agent misjudgement gets past them.

They do not, however, govern what the agent chooses to **put in front of the human**. An
evaluation of this skill found the agent proposing a stylistic edit to a line in a live file
while writing, in its own evidence record, that the unit was *"OPTIONAL, not dead code."* It
understood the boundary and argued its way past it. Separately, it declined two out-of-scope
units without writing the accompanying `kept` record, so both still read downstream as
proposed.

Neither failure is a capability failure — the agent knew the rule in both cases. They are
discipline failures, and the skill had nothing addressing that class. It stated prohibitions
but never named the reasoning that leads past them, and it had no single gate for "may this
unit be proposed at all?"

A survey of a mature skill corpus found the pattern that was missing: every discipline-
enforcing skill there pairs an **absolute rule** with a **table naming the exact
rationalizations** an agent reaches for. Rules phrased as suggestions get talked out of under
pressure; the excuse belongs on the page before it gets used.

## Decision

The `## The boundary` section now carries three tiers: an Iron Law, the standing prohibitions
(unchanged), and a rationalization table closing on a self-referential line.

**The Iron Law is anchored on candidacy, not on a probe verdict:**

```
NO PROPOSAL WITHOUT A CANDIDATE RECORD
```

The obvious formulation — *no proposal without a probe verdict* — is wrong for this skill, and
the reason is worth recording because it is not evident from the rule itself. Word-level
**prose** deletions carry **no `probe` record at all**: there is no machine oracle for meaning,
so `references/ledger-schema.md` routes them straight from candidate to proposal. A
probe-anchored law would have barred a documented capability outright.

Candidacy is the property that actually separates the observed failures from legitimate
proposals. Both offending units were **invented at approval time** and had never been
nominated. Prose proposals and `oracle-blind` units, by contrast, are both nominated at
Stage 1 and carried down — so they pass. The law reads "either as itself, or as the coarser
unit it descends from", because Stage 1 nominates the coarsest unit the evidence supports
while probes descend to `path:start-end`.

Two supporting changes: a bright line against running `cull.sh` before Stage 0 closes (a probe
against an undetected oracle returns verdicts indistinguishable from real ones), and remedy
clauses on two prohibitions that previously stated a rule with no recovery path.

## Rationale

**Why prose, when this skill ships scripts.** The mechanical form of this law is available:
`ledger.sh append` could reject a `proposal` whose unit has no prior `candidate` record, exit 2,
fail-closed like the existing content floor. That is **strictly stronger** than prose — the
failure being addressed is an agent rationalizing past instructions, and a script cannot be
argued with.

Prose ships first as a sequencing decision, not because it is sufficient. It is cheap, has no
failure modes, steers behaviour *before* the append call rather than rejecting after it, and
covers judgment no script can reach: scope, rationale quality, coverage honesty. The
mechanical check is tracked as follow-up work. **Anyone reading this should treat the prose as
the softer half.**

**Known limitation.** The law is gameable: an agent could nominate an out-of-scope unit as a
candidate at Stage 1 and then propose it. Stage 1 requires candidates to carry evidence, but
nothing validates that at append time. This weakens the *mechanism*, not the *safety posture* —
every proposal still passes the forced human approval turn and `cull.sh`'s guard chain.

## Consequences

- The skill grows from 111 to 134 lines; the stages, scripts, and ledger schema are unchanged.
- Three grep-based contract assertions pin the new invariants (the law verbatim inside a fenced
  block, the table header, the Stage-0 bright line). They pin **invariants, not prose** — the
  table's rows are expected to evolve as new failure modes are observed, so no assertion reads
  row contents.
- One table row ("I'm not sure, so I'll leave it out") is a deliberate counterweight rather than
  a response to an observed failure: every other element here pushes on restraint, so the row
  guards against the agent silently under-nominating and under-reporting coverage.
- The rationalization table is expected to grow. Adding a row when a new failure mode is
  observed is the intended maintenance path; removing the table is not.
