---
name: house-cleaning
description: Propose-only cleaner for dead code and cruft — finds provably-dead code with the deletion test and requires explicit approval before removing anything.
disable-model-invocation: true
---

# House-Cleaning

Deep-clean a repository with the **deletion test**: delete a unit — a whole dead
directory, a file, a region, a line, a word — and let the project's own **oracle**
(build, typecheck, tests) rule. Nothing observable changed? The unit is
**provably-dead**. The oracle objects, or can't see the unit at all
(**oracle-blind**)? It stays live. Here every deletion is a **probe** —
delete → oracle → **always revert** — that gathers evidence and commits nothing.
You probe, you **propose**, the human approves; only then do approved removals
apply. The append-only **coverage ledger** records every verdict so a massive
repo is cleaned incrementally across runs.

**Announce at start:** "Using house-cleaning to audit `<target>` (propose-only)."

**Scope:** `/house-cleaning [dir]` — default repo root. Scoping slices the audit; it never silently skips.

**When NOT to use:** a dirty working tree, an untrusted repo (the oracle runs its code), or when you want deletions applied without review — this tool asks first, every time.

## The boundary

```
NO PROPOSAL WITHOUT A CANDIDATE RECORD
```

If it never entered as a candidate, it does not leave as a proposal. Units are nominated at Stage 1 — in this run or a prior one — and carried down; they are not invented at approval time. Caught one after the fact? Drop it from the manifest and record a `kept`.

**Standing prohibitions**

- **Never auto-delete.** No removal applies without a **forced human** approval turn (Stage 4). `cull.sh apply` runs only the human-authorized manifest.
- Probes **always revert**: after any probe the tree is byte-identical to HEAD, and nothing is committed. Tree not byte-identical afterwards? `git checkout -- .` and re-probe — a dirty tree invalidates every verdict that follows.
- Approved deletions land as atomic, oracle-verified commits on a `house-cleaning/<date>` branch; **never merge red**.
- The committed ledger and audit hold identifiers + evidence-type + verdict only — never file contents, diffs, or code.
- **Never run `cull.sh` before Stage 0 closes.** A probe against an undetected oracle or an unverified baseline proves nothing — it produces verdicts that look identical to real ones.
- Carried floors (the scripts enforce these — don't restate them): clean tree (modulo `.house-cleaning/`) · `house-cleaning/*` branch only · keep-list untouchable · secret-shaped paths refuse · untracked archived before removal.
- **Record via the ledger, not by hand.** Every candidate, probe, and proposal MUST go through `scripts/ledger.sh` / `scripts/cull.sh` so the coverage ledger exists — never substitute a hand-rolled `cp`/`rm`/manual test-run probe for those scripts. Recorded by hand? The coverage ledger is wrong and resumption will lie — re-record through the script before the stage closes.

The run id set by `scripts/ledger.sh init` (Stage 0) sticks via `.house-cleaning/current-run` —
you do NOT need to re-export `HC_RUN_ID` on every call. Storage is committed by default
(`HC_LEDGER_MODE=committed`); flip to `local` for a no-commit, gitignored ledger. In committed
mode, flush the ledger/audit at stage boundaries with `scripts/ledger.sh checkpoint "$HC_RUN_ID"`.

## Stage 0 — Contract

Copy-paste setup, one shot — the run id sticks (see above), so nothing further to export:

```bash
git checkout -b house-cleaning/<yyyy-mm-dd>
scripts/ledger.sh init <yyyy-mm-dd-hhmm> <scope> "$(git rev-parse HEAD)"
```

1. Refuse a dirty tree (outside `.house-cleaning/`) or a non-git repo. Branch: as above — never main.
2. Oracle: `scripts/oracle.sh detect` prints proposed commands; **show them and get the user's confirmation** before writing `.house-cleaning/oracle`. Trust boundary — the oracle executes this repo's code.
3. Baseline: `scripts/oracle.sh run` twice. Red ⇒ stop and report. A flake ⇒ record it and demote confidence.
4. Keep-list: read `.house-cleaning/keep`; offer to seed it (entry points, migrations, licenses).
5. Run the setup above, then append the `oracle` and `baseline` records.

**Done when:** the ledger holds `run` + `oracle` + `baseline` records, the keep-list is read, and the `house-cleaning/<date>` branch exists.

## Stage 1 — Nominate (coarse-first)

Nominate candidates from static detectors (`references/tools.md`); dynamic languages need **two independent signals**. Nominate the **coarsest** unit the evidence supports — a whole dead directory or module is one candidate, not a hundred. Enumerate untracked files (`git ls-files --others --exclude-standard`) and classify them; untracked removals are **always proposals** (git can't undo them). Record each in-scope unit as a `candidate` (evidence + tier + granularity) or a `kept` record via `scripts/ledger.sh append "$HC_RUN_ID" candidate '{…}'`.

**Done when:** every in-scope unit is a `candidate` or `kept` ledger record, and `scripts/ledger.sh regen-audit "$HC_RUN_ID"` is refreshed.

## Stage 2 — Probe (coarse-to-fine — never applies)

Run the **deletion test**, **batch-first**: `scripts/cull.sh probe batch <listfile>` deletes the whole batch, runs the oracle once, and reverts. Collective green ⇒ every member is `provably-dead`; red ⇒ the script isolates the live members and the survivors descend **coarse-to-fine** to `scripts/cull.sh probe region|bisect <path> <start> <end>`. Every probe logs a verdict and records coverage; nothing is committed or applied.

`cull.sh probe` only ever writes `provably-dead` (oracle green) or `kept-live` (oracle red). A candidate the deletion test cannot safely evaluate at all — dynamic access, reflection, an untested path with no oracle coverage — you record as `oracle-blind` yourself (`scripts/ledger.sh append "$HC_RUN_ID" probe '{…}'`); an oracle-blind unit always becomes a proposal, never auto-anything.

**Done when:** every candidate carries a probe verdict — `provably-dead`, `oracle-blind`, or `kept-live` — in the ledger.

## Stage 3 — Word level (exhaustive-per-unit, coverage-incremental)

On the survivors only, go to word granularity. Code tokens: oracle-gated `probe region|bisect`, deletion only (never renaming); an oracle-surviving deletion that hurts a human reader demotes to a proposal. Prose (comments, docstrings, docs): meaning-based per `references/prose.md` — **always proposals**, no machine oracle. This is **budget-bounded**: exhaustive per unit examined, but coverage is incremental — on hitting the per-run budget, checkpoint and report the remainder, never truncate silently. End every run with the mandatory, forced-visible coverage summary — `scripts/ledger.sh coverage-summary "$HC_RUN_ID"` prints a `coverage:` line ("swept X of Y candidates; N uncovered"). Never claim "done" while coverage is partial.

**Done when:** in-scope survivors are audited to word level or a partial checkpoint is recorded, and the `coverage:` summary is shown.

## Stage 4 — Propose & approve (forced-visible-output; the security boundary)

Regenerate the audit — `scripts/ledger.sh regen-audit "$HC_RUN_ID"` — and present it as forced-visible-output, **grouped by confidence, evidence-forward**:

- **provably-dead** (oracle-green) — eligible for informed bulk approval ("N units, all oracle-verified dead, evidence attached").
- **oracle-blind / judgment-laden / prose** — per-item or small-group review.
- **security- or secret-shaped** — always individual; **never bulk-approvable**.

Request approval through the harness's structured question tool where available, else a **numbered plain-text list, then stop for the reply**. The human's selection **is** the apply manifest. Record each choice as a `decision` (approved/declined) ledger record — that record is audit trail, not the enforcement.

**Every declined unit also needs a `kept` record.** The `decision` says how the human ruled; the `kept` record says the unit stays, and it is the `kept` record that retracts the unit from the run's proposal set. Decline without one and the unit still reads as proposed to anyone auditing the run. This covers anything you surfaced and then ruled out — including items ruled out as **out of scope** rather than as live code (a config entry, a stylistic edit inside a live file). Better still, keep out-of-scope items out of the decision stream entirely: it is for units you are proposing to remove.

**MUST NEVER** write a `decision:approved` record or call `cull.sh apply` without a human authorization in the same turn — approval is a **forced human** turn, not an agent-authored record.

**Done when:** every proposed unit has a `decision` record, every declined unit also has a `kept` record, and the approved units form the apply manifest.

## Stage 5 — Apply approved

Apply **only** the approved manifest. Two paths, by granularity:

- **Whole-file / whole-unit** — `scripts/cull.sh apply <manifest>` (tracked — each deletion → oracle → atomic commit) and `scripts/cull.sh apply-untracked <listfile>` (untracked — archive-first). Both do a whole-path removal only; a region/word unit like `foo.ts:2-2` is not theirs to handle.
- **Region and word/token level** (judgment-laden) — apply these yourself; the mechanical auto-revert covers only the whole-file/whole-unit `cull.sh` verbs. Re-probe at current positions first (never replay stale line numbers), edit out the approved region/tokens, run `scripts/oracle.sh run`; on green commit atomically (append an `applied` record — `scripts/ledger.sh append "$HC_RUN_ID" applied '{…}'` — then `git commit`), on red `git checkout -- <file>` to restore and mark it `kept-live`.

**Final gate:** full `scripts/oracle.sh run`. Red ⇒ `git bisect` across the branch's atomic commits, revert the culprit, re-run to green — **never merge red**. Then regenerate the audit and persist the additive audit/ledger to the base branch: `scripts/ledger.sh persist-base <base_branch> "$HC_RUN_ID"` (additive-only — adds `.house-cleaning/` files, touches no code) so history and resumption survive even if the deletions are abandoned. Deletions stay on the `house-cleaning/<date>` branch; the merge or PR is the user's call.

**Done when:** approved deletions are atomic oracle-green commits, the final oracle is green, and the audit/ledger is persisted to the base branch.

## Resumption

On every invocation, read the ledger to see what scope has been swept and resume the uncovered remainder: `scripts/ledger.sh coverage-view --since` invalidates coverage for files changed since their recorded sha, so changed units are re-nominated and re-probed. "Know what scope you're looking at" is just the coverage summary — this is how the tool cleans a massive repo across many runs.

## Reference (branch-only)

- `references/tools.md` — dead-code detectors by ecosystem (Stage 1 signals).
- `references/prose.md` — word-level deletion rules for prose (Stage 3).
- `references/ledger-schema.md` — ledger record types and the audit projection.
