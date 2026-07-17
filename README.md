# house-cleaning

A garbage collector for codebases, packaged as a Claude Code skill.

The mechanic is the **deletion test**: delete a unit — a file, a region, a line,
a word — and let the project's own **oracle** (build + typecheck + tests) rule.
Nothing observable changed? It was dead weight; the deletion stays. The oracle
objects? A script restores it mechanically. Three progressive stages: dead
**files** (culling plan), dead **lines** (batch-first delta-debugging bisection),
dead **words** (exhaustive audit — code tokens by oracle, prose by meaning).

Every deletion is one atomic commit on a dedicated branch. Every verdict is
logged. Untracked files are archived before removal. Security-sensitive code
never auto-deletes. Nothing merges red.

## Install

Claude Code (as a plugin):

    /plugin install <this-repo-url>

Or copy `skills/house-cleaning/` into your skills directory.

## Use

    /house-cleaning            # deep-clean the repo
    /house-cleaning src/       # deep-clean one directory

The skill is user-invoked only — it never fires on its own.

**Requirements:** bash 4+, GNU coreutils + GNU sed, git. (BSD/macOS userland is not
supported in v1 — the scripts refuse rather than risk silent misbehavior.)

## Safety model

- Clean tree + double-green baseline required; work happens on `house-cleaning/<date>`.
- One deletion = one atomic commit; a red oracle triggers mechanical restore.
- Tiered application: only oracle-verified, coverage-backed candidates auto-apply;
  everything judgment-laden is a proposal for human review.
- Untracked deletions are tar-archived first; git can't undo them, the archive can.

## Lineage

- Jeremy Longshore — [cleanup-code](https://github.com/jeremylongshore/claude-code-plugins-plus-skills): risk-ordered dimensions, confidence tiers.
- John Wiegley — [eliminate-dead-code](https://github.com/jwiegley/promptdeploy): phase discipline, two-evidence rule.
- Matt Pocock — the deletion test for skill prose, applied here to everything.
- Mutation-testing literature — statement deletion (SDL) and the equivalent-mutant caveat: a green oracle is evidence, not proof; oracle quality is the confidence level.

MIT.
