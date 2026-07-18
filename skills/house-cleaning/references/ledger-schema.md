# Ledger schema

The canonical record of a house-cleaning run is `.house-cleaning/runs/<run_id>/ledger.jsonl`
— an append-only, one-JSON-object-per-line log written by `scripts/ledger.sh append` (and,
for a few types, directly by `scripts/cull.sh`). `audit.md` in the same run directory is a
**regenerated projection** of that ledger, never hand-edited; the ledger is the single source
of truth. Nothing in either file ever holds file contents, diffs, or code — see
[Format & the no-content rule](#format--the-no-content-rule).

This document describes the **actual** shapes `ledger.sh` and `cull.sh` write today, read
straight from the scripts, not the aspirational table in the design spec — the two have
diverged in a few places called out below.

## Contents

- [Format & the no-content rule](#format--the-no-content-rule)
- [Record types at a glance](#record-types-at-a-glance)
- [Record types in detail](#record-types-in-detail)
  - [`run`](#run) · [`oracle`](#oracle) · [`baseline`](#baseline) · [`candidate`](#candidate) ·
    [`kept`](#kept) · [`probe`](#probe) · [`decision`](#decision) · [`applied`](#applied) ·
    [`proposal`](#proposal-not-currently-emitted) · [`coverage`](#coverage-not-currently-emitted)
- [Coverage is derived, not stored](#coverage-is-derived-not-stored)
- [`audit.md` — the regenerated projection](#auditmd--the-regenerated-projection)
- [Storage mode (`HC_LEDGER_MODE`)](#storage-mode-hc_ledger_mode)

## Format & the no-content rule

Every record is a single-line JSON object (`jq -c`), written by `ledger.sh append <run_id>
<type> <json_fields>`. `append` merges in `type` and a UTC `ts` automatically — callers never
set those themselves.

**Security floor, enforced mechanically, not by convention:** `append` rejects any record
whose fields contain the key `content`, `diff`, `code`, `body`, or `snippet` — **at any
nesting depth**, not just top-level (`{"evidence":{"content":"..."}}` is refused exactly like
a top-level `{"content":"..."}`). A record can name a unit and describe an evidence *type* or
oracle *verdict*; it can never carry the unit's actual text. A violation refuses with exit 2
before anything is written — there is no code path that writes a partial or forbidden record.

## Record types at a glance

| type | who writes it | carries `git_sha`? |
|---|---|---|
| [`run`](#run) | `ledger.sh init` | yes |
| [`oracle`](#oracle) | agent, via `append` (Stage 0) | no |
| [`baseline`](#baseline) | agent, via `append` (Stage 0) | no |
| [`candidate`](#candidate) | agent, via `append` (Stage 1) | no |
| [`kept`](#kept) | agent, via `append` (Stage 1) | no |
| [`probe`](#probe) | `cull.sh probe *` (mechanical verdicts) + agent (`oracle-blind`) | **yes, always** |
| [`decision`](#decision) | agent, via `append` (Stage 4) | no |
| [`applied`](#applied) | `cull.sh apply` / `apply-untracked` + agent (region/word, Stage 5) | no (`sha` instead) |
| [`proposal`](#proposal-not-currently-emitted) | *no current writer* | — |
| [`coverage`](#coverage-not-currently-emitted) | *no current writer* | — |

## Record types in detail

### `run`

Written once by `ledger.sh init <run_id> <scope> <git_sha>`, the first line of every run's
ledger.

```json
{"type":"run","run_id":"2026-07-18-1400","scope":"src","git_sha":"a1b2c3d","ts":"2026-07-18T14:00:00Z"}
```

Fields: `run_id`, `scope`, `git_sha`, `ts`. **Deviation from the design spec:** the spec's
table adds an `oracle_confirmed` field to `run` — the implementation doesn't write one; the
Stage-0 oracle-confirmation step is instead evidenced by the separate `oracle` record below
existing at all in the run's ledger, not by a boolean on `run`.

### `oracle`

Agent-authored (SKILL.md Stage 0, step 5: "append the `oracle` and `baseline` records"). No
script writes this type; the shape below is the convention `regen-audit` expects
(`.commands | join(" ; ")`) and the only one worth using.

```json
{"type":"oracle","commands":["npm run build","npm test"],"ts":"2026-07-18T14:00:05Z"}
```

Fields: `commands` (array of strings — the confirmed oracle invocation(s)).

### `baseline`

Agent-authored, same Stage-0 step. Convention expected by `regen-audit`
(`.result`, optional `.flake`):

```json
{"type":"baseline","result":"green","ts":"2026-07-18T14:00:20Z"}
```

A flaky double-run baseline demotes confidence rather than blocking:

```json
{"type":"baseline","result":"green","flake":true,"ts":"2026-07-18T14:00:20Z"}
```

Fields: `result` (`green`|`red`), `flake` (optional boolean).

### `candidate`

Agent-authored (SKILL.md Stage 1), one per in-scope unit nominated for the deletion test.
Exact shape confirmed by `tests/resumption.test.sh` and consumed by `coverage-summary`'s
candidate/probe membership count:

```json
{"type":"candidate","unit":"src/legacy/util.ts","granularity":"file","evidence":["knip"],"tier":"HIGH","source":"knip","ts":"2026-07-18T14:01:00Z"}
```

Fields: `unit`, `granularity` (`file`|`region`|`line`|`word`), `evidence` (array of detector
names), `tier`, `source`.

### `kept`

Agent-authored (SKILL.md Stage 1: "Record each in-scope unit as a `candidate` ... or a `kept`
record"), for units examined but not even nominated for probing (e.g. an entry point a
detector flagged but the agent judged live on inspection).

```json
{"type":"kept","unit":"src/index.ts","reason":"entry point","ts":"2026-07-18T14:01:05Z"}
```

**Known gap:** `regen-audit` has no `select(.type=="kept")` section and `coverage-view`
aggregates only `probe`/`coverage` types — a written `kept` record is durable in the raw
`ledger.jsonl` but today renders in **neither** `audit.md` nor the coverage view. SKILL.md's
Stage-1 "Done when" (`every in-scope unit is a candidate or kept ledger record`) is satisfiable
without that record ever surfacing anywhere downstream.

### `probe`

The deletion test's verdict record. Two verdicts are written mechanically by `cull.sh probe
file|region|bisect|batch` — `provably-dead` (oracle green) and `kept-live` (oracle red) — and
carry the `git_sha` of `HEAD` at probe time on **every** granularity, including bisect and
batch descents (each ddmin round threads the *batch-entry* sha through its recursive calls
rather than re-reading `HEAD`, since a probe never commits mid-batch). A third verdict,
`oracle-blind`, is agent-authored for units the deletion test can't safely evaluate at all
(dynamic access, reflection, no oracle coverage) — `cull.sh` never writes it.

```json
{"type":"probe","unit":"src/legacy/util.ts","granularity":"file","verdict":"provably-dead","oracle":"green","tier":"HIGH","git_sha":"a1b2c3d","ts":"2026-07-18T14:02:00Z"}
{"type":"probe","unit":"src/legacy/util.ts:40-52","granularity":"region","verdict":"kept-live","oracle":"red","git_sha":"a1b2c3d","ts":"2026-07-18T14:02:10Z"}
{"type":"probe","unit":"src/plugins/loader.ts","granularity":"file","verdict":"oracle-blind","reason":"loaded via dynamic require, no test path exercises it","ts":"2026-07-18T14:02:30Z"}
```

Fields: `unit`, `granularity` (`file`|`region`|`line`|`word`; `word` is agent-authored only —
no script probes at word granularity), `verdict` (`provably-dead`|`kept-live`|`oracle-blind`),
`oracle` (`green`|`red`, absent on `oracle-blind` since no oracle ran), `tier` (present on
`probe file`/`probe region`'s green path only — `probe bisect` and `probe batch` never stamp
it), `git_sha` (always present on script-emitted probes).

Two implementation details worth knowing when reading raw records:
- **`granularity` is not the verb.** `probe bisect`'s recursive descent writes `granularity:
  "region"` on a green (non-recursing) leaf and `"line"` on a red base case
  (`start >= end`) — there is no `"bisect"` granularity value. `probe batch`'s ddmin always
  writes `granularity: "file"` — there is no `"batch"` value either.
- `unit` for region/bisect probes is `"<path>:<start>-<end>"` (colon-delimited range suffix);
  `coverage-view`/`coverage-summary` parse that suffix back off with a regex, not a separate
  field.

### `decision`

Agent-authored (SKILL.md Stage 4), one per proposed unit the human ruled on:

```json
{"type":"decision","unit":"src/legacy/util.ts","decision":"approved","by":"user","ts":"2026-07-18T14:05:00Z"}
```

Fields: `unit`, `decision` (`approved`|`declined`), `by` (`user`). **Last-write-wins per
unit:** `cull.sh apply`'s `_is_approved` check reads all `decision` records for a unit and
looks only at the *last* one — re-deciding a unit (approve, then later decline the same
run's proposal) supersedes the earlier record rather than conflicting with it. This record is
audit trail, not the enforcement boundary itself — the boundary is that no code path writes
`decision:approved` or calls `cull.sh apply` without a human authorizing it in that turn.

### `applied`

Written when a unit is actually removed for real (never during a probe). Three writers:

- `cull.sh apply` (tracked units) — writes `sha:"PENDING"` and commits the ledger line
  **atomically with the deletion**, in the same commit:

  ```json
  {"type":"applied","unit":"src/legacy/util.ts","sha":"PENDING","ts":"2026-07-18T14:06:00Z"}
  ```

  `PENDING` is not a placeholder that later gets backfilled — it's permanent. The real
  commit sha doesn't exist yet at the moment the record is written (chicken-and-egg: the
  ledger line is part of the commit it would need to name), so the script's own comment
  documents the intended lookup: derive it from `git log` against the unit's path at audit
  time rather than from this field.

- `cull.sh apply-untracked` (untracked units, archived first) — writes `sha:"untracked-
  archived"` only on a green group oracle, one record per archived unit:

  ```json
  {"type":"applied","unit":"tmp/scratch.log","sha":"untracked-archived","ts":"2026-07-18T14:06:30Z"}
  ```

  A red group oracle restores the whole archive and leaves **no** `applied` record for any
  unit in it — a restored unit was never actually applied.

- The agent, directly (SKILL.md Stage 5, region/word-level deletions the mechanical `cull.sh`
  verbs don't handle) — same `{unit, sha}` convention, written just before the human's own
  `git commit`; nothing in the scripts validates this call site's shape.

Fields: `unit`, `sha` (`"PENDING"` | `"untracked-archived"` | agent-supplied for the manual
path — never a real sha for tracked applies).

### `proposal` (not currently emitted)

The design spec's data-model table lists a `proposal` type (`unit, recommendation,
confidence, security_capped?`), and `ledger.sh regen-audit` still carries a
`select(.type=="proposal")` projection section for it. **No current script call site or
SKILL.md instruction writes one.** Stage 4 ("Propose & approve") presents proposals directly
from the run's `candidate`/`probe` records, grouped by confidence at presentation time — it
never persists a separate `proposal` record first. If a future run does write one, it will
render correctly in `audit.md`'s "Proposals" section; today that section is always empty.

### `coverage` (not currently emitted)

Same situation: the spec lists a `coverage` type (`scope, granularity, status, git_sha, ts`),
`regen-audit` has a `select(.type=="coverage")` section for it, and `coverage-view`'s
aggregation query is written to accept it (`select(.type=="probe" or .type=="coverage")`,
falling back to `.scope` when `.unit` is absent). **Nothing writes this type.** All of the
tool's actual coverage functionality — see the next section — is a read-time query over
`candidate`/`probe` records, not a persisted `coverage` record. Both the `regen-audit`
"Coverage" section and any `.scope`-keyed entry in `coverage-view`'s output are dead branches
under current usage.

## Coverage is derived, not stored

There is no ledger record type that means "this file/run is done." Instead, three read-time
queries over the existing `candidate`/`probe` records answer "how much has been swept":

- **`ledger.sh coverage-view`** — aggregates every run's ledger (`runs/*/ledger.jsonl`,
  file-glob-sorted, so run order tracks run-id order) into `{unit: {granularity, verdict,
  git_sha}}`, last record per unit wins across runs.
- **`ledger.sh coverage-view --since`** — the same aggregation, but drops any unit whose
  `git_sha` is missing, unresolvable, or whose underlying file has changed since that sha
  (`git diff --name-only <sha> HEAD -- <file>`). Fails closed: a unit with no recorded
  `git_sha` at all is treated as never covered, not as covered-by-default.
- **`ledger.sh coverage-summary <run_id>`** — counts distinct `candidate` units in the run
  against how many are "swept" by *membership*, not by record count: a bisect or batch probe
  can split one candidate into several leaf `probe` records, so counting probe records
  directly would over-report coverage. A file candidate is swept by any same-file probe; a
  region candidate `F:a-b` is swept by an exact match, a sub-range fully inside `[a,b]`, or
  any whole-file probe on `F`. Output is a `coverage:` line ("swept X of Y candidates; N
  uncovered"); it appends "— run again to continue" whenever uncovered > 0, and never claims
  completion while any candidate is unswept.

## `audit.md` — the regenerated projection

`ledger.sh regen-audit <run_id>` regenerates `.house-cleaning/runs/<run_id>/audit.md`
**entirely from that run's `ledger.jsonl`** — it is a projection, not a second store, and is
safe to delete and regenerate at any time. Sections, in order: Scope & oracle (`run` +
`oracle` + `baseline`), Candidates & verdicts (`probe`), Proposals (`proposal` — currently
always empty, see above), Decisions & applied (`decision` + `applied`), Coverage (`coverage`
— currently always empty, see above). `kept` records appear in none of these sections (see
[`kept`](#kept)).

## Storage mode (`HC_LEDGER_MODE`)

Everything above is written the same way regardless of mode; what differs is whether it ever
leaves the working tree as a commit.

- **`committed`** (default) — `ledger.sh checkpoint <run_id>` commits
  `.house-cleaning/runs/<run_id>/` on the current (`house-cleaning/*`) branch as its own
  dedicated, pathspec-restricted commit. `ledger.sh persist-base <base_branch> <run_id>`
  additionally checks out the base branch, pulls that same run directory across
  (`git checkout <current> -- <run_dir>`), and commits it there too — additive-only, touching
  no code paths — before returning to the working branch. Both are idempotent: a second call
  with nothing new to commit is a silent no-op, not an error. A failed return to the working
  branch HALTs loudly (exit 3) with the exact recovery command rather than silently stranding
  the caller on the base branch.
- **`local`** — `checkpoint` and `persist-base` are no-ops beyond adding
  `.house-cleaning/` to `.git/info/exclude`; nothing is ever committed anywhere.
