# house-cleaning

A garbage collector for codebases, packaged as a Claude Code skill.

The mechanic is the **deletion test**: delete a unit — a file, a region, a line,
a word — and let the project's own **oracle** (build + typecheck + tests) rule.
Nothing observable changed? That's a **probe** verdict of provably-dead —
evidence, not an action. The oracle objects? A script restores it mechanically,
always. Every probe reverts; nothing is deleted for real until a human approves
it. Three progressive stages: dead **files** (batch-first delta-debugging
bisection), dead **lines** (region/bisect), dead **words** (exhaustive audit —
code tokens by oracle, prose by meaning).

Every *approved* deletion is one atomic, oracle-verified commit on a dedicated
branch. Every verdict is logged to a durable, committed audit ledger. Untracked
files are archived before removal. Nothing auto-deletes — not even
oracle-verified candidates — and security- or secret-shaped candidates are
never bulk-approvable. Nothing merges red.

## Install

Claude Code (as a plugin):

    /plugin install https://github.com/DollarDill/house-cleaning

Or copy `skills/house-cleaning/` into your skills directory.

## Use

    /house-cleaning:house-cleaning            # plugin install
    /house-cleaning [dir]                     # bare-copy install (skills directory)

The skill is user-invoked only.

**Requirements:** bash 4+, GNU coreutils + GNU sed, git, **jq**. (BSD/macOS
userland is not supported — the scripts refuse rather than risk silent
misbehavior.)

## Safety model

- **Propose-only.** Nothing is deleted without an explicit human-approval turn.
  The deletion test **probes** — delete → oracle → **always revert** — to
  gather evidence; a probe never commits and never leaves the tree changed,
  regardless of its verdict.
- **Confidence-grouped, evidence-forward proposals.** Oracle-verified
  (provably-dead) candidates are eligible for informed bulk approval;
  oracle-blind, judgment-laden, and prose candidates get per-item or
  small-group review. Security- and secret-shaped candidates are **never**
  bulk-approvable.
- Clean tree + double-green baseline required before a run starts; work
  happens on a `house-cleaning/<date>` branch, never `main`. One *approved*
  deletion = one atomic, oracle-verified commit; a red oracle on an applied
  unit restores it and halts — nothing merges red.
- **Durable, committed audit.** A per-run JSONL ledger plus a regenerated
  `audit.md` report is committed on the working branch and additively
  persisted onto the base branch, so the audit trail is team-visible,
  versioned, and survives even an abandoned cleanup. Records hold unit
  identifiers, evidence type, and verdicts only — never file contents, diffs,
  or code (enforced mechanically, not by convention). Committed mode
  force-adds its own `.house-cleaning/` ledger, so upgrading from v1 (or
  having run `local` mode once) — either of which can leave `.house-cleaning/`
  git-ignored in this repo — doesn't silently disable it.
- Untracked deletions are tar-archived before removal — git can't undo them,
  the archive can; the keep-list and secrets floor are honored throughout.

## Lineage

- Jeremy Longshore — [cleanup-code](https://github.com/jeremylongshore/claude-code-plugins-plus-skills): risk-ordered dimensions, confidence tiers.
- John Wiegley — [eliminate-dead-code](https://github.com/jwiegley/promptdeploy): phase discipline, two-evidence rule.
- Matt Pocock — the deletion test for skill prose, applied here to everything.
- Mutation-testing literature — statement deletion (SDL) and the equivalent-mutant caveat: a green oracle is evidence, not proof; oracle quality is the confidence level.

MIT.
