---
name: house-cleaning
description: Progressive deletion-test garbage collector for a codebase. Culls dead files, then dead lines, then dead words — every deletion verified by the project's own oracle (build, typecheck, tests) and logged. Invoked deliberately by the user; never fires on its own.
disable-model-invocation: true
---

# House-Cleaning

Deep-clean a repository with the **deletion test**: delete a unit — file, region, line, word — and let the **oracle** rule. If nothing observable changes, it was dead weight; the deletion stays. If the oracle objects, the script restores it mechanically. Every verdict is logged; everything is reversible.

**Announce at start:** "Using house-cleaning to deep-clean `<target>`."

Scope: `/house-cleaning [dir]` — default repo root. Scoping slices a deep clean; it never silently skips. A full clean is a long, deliberate operation by design.

## Stage 0 — Contract

1. Refuse on a dirty tree. Refuse outside a git repo.
2. Branch: `git checkout -b house-cleaning/<yyyy-mm-dd>` — never work on main.
3. Oracle: run `scripts/oracle.sh detect`, show the proposed commands, and get the user's confirmation before writing them to `.house-cleaning/oracle`. **Trust boundary: the oracle executes this repo's code — the user confirms they trust the repo.** No confirmed oracle ⇒ proposals-only mode (nothing auto-applies).
4. Baseline: `scripts/oracle.sh run` twice. Red ⇒ stop and report. Any flake logged ⇒ **unstable oracle: all-proposals mode**.
5. Keep-list: read `.house-cleaning/keep` (globs) if present; offer to seed it (entry points, migrations, licenses).

*Done when: `CULLING.md` exists at the target root recording oracle commands, double-green baseline, keep-list, and scope.*

## Stage 1 — Culling plan (files)

Build the candidate manifest in `CULLING.md`. Every file in scope ends up in exactly one bucket: **candidate** (with evidence + tier) or **kept** (with reason).

- Tracked files: run the language's dead-code detector (see `references/tools.md`) + corroborating signals (no inbound imports, build-artifact patterns, git recency). Dynamic languages require **two independent evidence signals** per candidate.
- Untracked files: enumerate (`git ls-files --others --exclude-standard`), classify (artifact / result / stale working doc / unknown), and propose. Untracked deletions are **always proposals** — git cannot undo them.

**Tiers** (auto-apply eligibility):
- **HIGH** — oracle-verified dead + 2 evidence signals + availability checks: (a) the oracle contains a test command, (b) baseline executed ≥1 test, (c) the candidate's neighborhood is demonstrably seen by the oracle (imported/reachable from tests, or covered per coverage data). Auto-applies.
- **MEDIUM** — oracle-green but judgment-laden (annotations, comments, docs). Proposal.
- **LOW** — oracle-blind (dynamic access, untested paths). Proposal, with warning.
- **Security cap:** candidates matching security-sensitive paths/symbols (auth, crypto, sanitize, middleware, permission, rate-limit, session, csrf) cap at proposal tier regardless of evidence — tests rarely assert absence-of-vulnerability.

*Done when: every in-scope file is a candidate row or an explicit keep.*

## Stage 2 — Deletion test (batch → files → regions → lines)

Batch-first: write HIGH-tier candidate paths to a list file, then `scripts/cull.sh batch <list> HIGH` — one oracle run for the whole batch; on red the script ddmin-bisects to isolate the live members. Then per surviving file: suspect regions via `scripts/cull.sh region|bisect`. The script commits every kept deletion atomically and restores every rejected one — restoration is never your judgment call.

Apply `cull.sh untracked <list>` to approved untracked proposals: it tars them to `.house-cleaning/untracked-*.tar.gz` **before** removal — the undo of last resort.

*Done when: every candidate row carries a verdict — `deleted@sha` / `kept-live` / `proposed` — regenerated into `CULLING.md` from `.house-cleaning/verdicts.log` (every log line accounted for).*

## Stage 3 — Word level (exhaustive audit)

Read every remaining in-scope file in full. Every token, every word, considered for deletion — no sampling, no shortlist substitute. Linter hints and pattern greps (identity operands, redundant qualifiers) order the work; they never bound it.

- Code tokens: strict deletion only — never renaming. Collect per-file deletions, apply as one batch, `scripts/oracle.sh run`, bisect on red. Oracle-surviving deletions that could hurt a human reader (explicit type annotations, clarifying qualifiers) demote to proposals.
- Prose (comments, docstrings, docs): apply the deletion test per sentence and per word — if removing it loses no meaning for the reader, remove it (see `references/prose.md`). Prose has no machine oracle: all non-trivial prose deletions are proposals.

*Done when: every in-scope file audited; word-deltas recorded; proposals complete.*

## Final gate

1. `scripts/oracle.sh run` — full re-run. **Red ⇒ `git bisect` across the branch's atomic commits** (each is one deletion group): find the culprit, revert it, re-run; repeat to green. Never merge red.
2. Present all proposals for review; apply approved ones through the same cull commands.
3. Regenerate `CULLING.md` from the verdict log; copy the log to `CULLING.log`; remove `.house-cleaning/` (the untracked archive is offered to the user first).
4. Merge/PR is the user's decision.

If the project runs an agent-aware tracker, mirror candidate rows as issues; `CULLING.md` remains the source of truth.

## Bright lines

- Preconditions or refuse: clean tree · double-green baseline · `house-cleaning/*` branch.
- One deletion = one atomic commit. Red oracle ⇒ the script restores — never discretion.
- Never: force-push, history rewrite, deleting VCS metadata, secrets/env files, or keep-list matches.
- Verification is never self-judgment: machine oracle for auto-apply; logged human approval for everything else.
