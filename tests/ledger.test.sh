# tests/ledger.test.sh — ledger.sh suite (new, T1). Sourced by run-tests.sh; uses harness
# helpers/vars: fail, $LEDGER. Each test_* function is discovered and invoked by run-tests.sh.
# Each test makes its own `mktemp -d` fixture repo and removes it with an explicit `rm -rf
# "$d"` as its last statement (deliberately NOT a `trap ... RETURN`: that trap is a global
# slot in bash, not scoped to the function that set it — since these functions are invoked
# indirectly via `"$fn"` from inside run-tests.sh's own `_run_suite`, a RETURN trap set here
# fires again on `_run_suite`'s own return, referencing this function's already-gone local
# `$d` and aborting the whole run under `set -u`; verified by hitting exactly that failure).
# A `fail` (which exits the whole run before reaching the cleanup line) deliberately leaves
# the dir behind for post-mortem debugging.

test_ledger_append_writes_valid_jsonl() {
  local d; d="$(mktemp -d)"; ( cd "$d" && git init -q )
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init run1 src abc123 \
      && HC_LEDGER_MODE=committed bash "$LEDGER" append run1 probe \
         '{"unit":"src/dead.ts","granularity":"file","verdict":"provably-dead","oracle":"green","git_sha":"abc123"}' )
  local line; line="$(tail -1 "$d/.house-cleaning/runs/run1/ledger.jsonl")"
  echo "$line" | jq -e '.type=="probe" and .unit=="src/dead.ts"' >/dev/null || fail "probe record not valid/complete"
  rm -rf "$d"
}

test_ledger_append_refuses_content() {
  local d; d="$(mktemp -d)"; ( cd "$d" && git init -q )
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init run1 src abc123 )
  if ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" append run1 probe \
         '{"unit":"x","content":"SECRET=hunter2"}' ) 2>/dev/null; then
    fail "append accepted a record containing forbidden 'content' key"
  fi
  rm -rf "$d"
}

test_ledger_append_refuses_nested_content() {
  local d; d="$(mktemp -d)"; ( cd "$d" && git init -q )
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init run1 src abc123 )
  if ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" append run1 probe \
         '{"unit":"x","evidence":{"content":"SECRET=hunter2"}}' ) 2>/dev/null; then
    fail "append accepted a record with a NESTED forbidden 'content' key"
  fi
  rm -rf "$d"
}

test_coverage_view_last_write_wins() {
  local d; d="$(mktemp -d)"; ( cd "$d" && git init -q )
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init r1 . s1
    bash "$LEDGER" append r1 probe '{"unit":"a.ts","granularity":"file","verdict":"kept-live","git_sha":"s1"}'
    bash "$LEDGER" init r2 . s2
    bash "$LEDGER" append r2 probe '{"unit":"a.ts","granularity":"file","verdict":"provably-dead","git_sha":"s2"}' )
  local v; v="$( cd "$d" && bash "$LEDGER" coverage-view | jq -r '."a.ts".verdict' )"
  [ "$v" = "provably-dead" ] || fail "coverage-view should be last-write-wins (got '$v')"
  rm -rf "$d"
}

test_regen_audit_from_ledger_only() {
  local d; d="$(mktemp -d)"; ( cd "$d" && git init -q )
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init r1 src s1
    bash "$LEDGER" append r1 probe '{"unit":"dead.ts","granularity":"file","verdict":"provably-dead","git_sha":"s1"}'
    bash "$LEDGER" regen-audit r1 )
  grep -q "dead.ts" "$d/.house-cleaning/runs/r1/audit.md" || fail "audit.md missing unit"
  grep -q "provably-dead" "$d/.house-cleaning/runs/r1/audit.md" || fail "audit.md missing verdict"
  rm -rf "$d"
}

# T1 (cc-eval-aeut4): run-id stickiness (init writes .house-cleaning/current-run;
# resolve-run-id subcommand reads it back in a fresh shell with HC_RUN_ID unset) +
# allowlist sanitization (traversal / absolute / leading-dash / dot-only / leading-
# underscore all rejected, from both the current-run file AND HC_RUN_ID). Spec regex is
# ^[A-Za-z0-9][A-Za-z0-9_-]*$ — first char must be alphanumeric, so a leading underscore
# ('_foo', bare '_') must reject too, even though underscore is allowed mid-string.
test_stickiness_and_sanitization() {
  local tmp; tmp="$(mktemp -d)"; ( cd "$tmp" && git init -q
    bash "$LEDGER" init 2026-07-22-1200 repo-root "$(git rev-parse HEAD 2>/dev/null || echo none)"
    [ "$(cat .house-cleaning/current-run)" = "2026-07-22-1200" ] || { echo FAIL stickiness-write; exit 1; }
    # fresh shell, HC_RUN_ID unset -> resolves from file via the subcommand
    local rid; rid="$(env -u HC_RUN_ID bash "$LEDGER" resolve-run-id 2>/dev/null)"
    [ "$rid" = "2026-07-22-1200" ] || { echo FAIL stickiness-resolve; exit 1; }
    # allowlist rejects each unsafe shape
    for bad in '../../etc' '/etc' '-rf' '.' '_foo' '_'; do
      printf '%s' "$bad" > .house-cleaning/current-run
      if env -u HC_RUN_ID bash "$LEDGER" resolve-run-id 2>/dev/null; then echo "FAIL unsafe-not-rejected: $bad"; exit 1; fi
      HC_RUN_ID="$bad" bash "$LEDGER" resolve-run-id 2>/dev/null && { echo "FAIL env-unsafe: $bad"; exit 1; }
    done
    true   # normalize $? to 0: the loop's last command is an EXPECTED rejection (nonzero
           # exit) when the implementation is correct, so without this the subshell's own
           # exit status would spuriously trip the `|| exit 1` below on a passing run —
           # every genuine FAIL path above already `exit 1`s explicitly and is unaffected.
  ) || exit 1; rm -rf "$tmp"; echo "ok: stickiness+sanitization"
}

# T2 (cc-eval-mvyyg Task 2): lazy-init (fresh-only) + current-run reinit repoint.
# (a) `append` with NO prior init at all (no run dir exists) auto-creates the run dir +
#     a lazy "run" record and writes the caller's record — no "not initialized" refusal.
#     Invoked with an explicit empty run-id arg so it must resolve via HC_RUN_ID
#     (Task 1's `_resolve_run_id` path), never treating the `type` arg as a run id.
# (c) lazy-init is scoped to "no run dir exists AT ALL for the resolved id" — it must
#     never redirect into, or mutate, a *different* pre-existing (stale) run dir: here a
#     run "2026-07-22-0800" is init'd first (stale), current-run is then repointed at a
#     brand-new uninitialized id "2026-07-22-0930", and a fresh-shell append (HC_RUN_ID
#     unset) must lazy-init ONLY the new id's dir, leaving the stale run byte-identical.
# (b) a second `init` overwrites .house-cleaning/current-run with the new id.
test_lazy_init_and_reinit() {
  local tmp; tmp="$(mktemp -d)"; ( cd "$tmp" && git init -q
    [ ! -d .house-cleaning/runs ] || { echo FAIL precondition-runs-exists; exit 1; }
    HC_RUN_ID=2026-07-22-0900 bash "$LEDGER" append "" candidate '{"unit":"a.js"}'
    [ -f .house-cleaning/runs/2026-07-22-0900/ledger.jsonl ] || { echo FAIL lazy-init; exit 1; }
    grep -q '"unit":"a.js"' .house-cleaning/runs/2026-07-22-0900/ledger.jsonl || { echo FAIL lazy-init-record; exit 1; }

    bash "$LEDGER" init 2026-07-22-0800 repo-root none   # unrelated earlier run -> now "stale"
    local stale_before; stale_before="$(cat .house-cleaning/runs/2026-07-22-0800/ledger.jsonl)"
    printf '%s' '2026-07-22-0930' > .house-cleaning/current-run   # repoint at a NEW, uninitialized id
    env -u HC_RUN_ID bash "$LEDGER" append "" candidate '{"unit":"b.js"}'
    [ -f .house-cleaning/runs/2026-07-22-0930/ledger.jsonl ] || { echo FAIL lazy-init-new-current; exit 1; }
    [ "$(cat .house-cleaning/runs/2026-07-22-0800/ledger.jsonl)" = "$stale_before" ] || { echo FAIL stale-run-mutated; exit 1; }

    bash "$LEDGER" init 2026-07-22-1000 repo-root none
    [ "$(cat .house-cleaning/current-run)" = "2026-07-22-1000" ] || { echo FAIL reinit-repoint; exit 1; }
  ) || exit 1; rm -rf "$tmp"; echo "ok: lazy-init+reinit"
}

# T2 review fix (Important, spec review): `_valid_run_id` must run UNCONDITIONALLY once
# `run_id` is finalized, BEFORE the lazy-init `[ ! -d "$dir" ]` test — not only inside that
# branch. Bug: when an explicit unsafe run id's target dir HAPPENS TO ALREADY EXIST (e.g. a
# repo that legitimately has an `etc/` directory two levels above `.house-cleaning/runs/`,
# or `.` which resolves to `.house-cleaning/runs` itself as soon as any run has ever been
# created), the old `if [ ! -d "$dir" ]` guard was skipped entirely — so `_valid_run_id`
# never ran and a record was written OUTSIDE `.house-cleaning/runs/` with no sanitization
# (empirically: after any `init`, pre-creating `etc/` then `append '../../etc' ...` wrote
# `etc/ledger.jsonl` at exit 0). This test reproduces that exact precondition — the target
# dir for each unsafe id is created FIRST — and asserts the (now-hoisted) guard still
# refuses and writes nothing into it.
test_append_sanitizes_run_id_even_when_target_dir_preexists() {
  local tmp; tmp="$(mktemp -d)"; ( cd "$tmp" && git init -q
    bash "$LEDGER" init legit-run repo-root none
    for bad in '../../etc' '/etc' '-rf' '.' '_foo'; do
      local target=".house-cleaning/runs/$bad"
      mkdir -p "$target"   # simulate the reported precondition: the target already exists
      if bash "$LEDGER" append "$bad" probe '{"unit":"x"}' 2>/dev/null; then
        echo "FAIL unsafe-accepted-preexisting-dir: $bad"; exit 1
      fi
      [ ! -f "$target/ledger.jsonl" ] || { echo "FAIL unsafe-wrote-record: $bad"; exit 1; }
    done
    # the concrete historical escape target: two levels above runs/ is the repo root, so
    # '../../etc' must never land a ledger file at "$tmp/etc/ledger.jsonl".
    [ ! -f "$tmp/etc/ledger.jsonl" ] || { echo "FAIL traversal-escaped-top-level: etc/ledger.jsonl exists"; exit 1; }
    # the legit run's own ledger must be untouched by any of the rejected attempts.
    grep -q '"type":"run"' .house-cleaning/runs/legit-run/ledger.jsonl || { echo FAIL legit-run-corrupted; exit 1; }
  ) || exit 1; rm -rf "$tmp"; echo "ok: append-sanitizes-even-when-dir-exists"
}

# T2 review fix (Minor, spec review): the truly-blank fallback (no explicit run id, no
# HC_RUN_ID, no .house-cleaning/current-run at all) was implemented but never exercised by
# a test — cover it explicitly: it must succeed (exit 0) and auto-create a run dir whose
# name matches the UTC-timestamp default shape (YYYY-MM-DD-HHMMSS), not merely "some dir".
test_append_blank_id_falls_back_to_timestamp_default() {
  local tmp; tmp="$(mktemp -d)"; ( cd "$tmp" && git init -q
    [ ! -f .house-cleaning/current-run ] || { echo FAIL precondition-current-run-exists; exit 1; }
    if ! env -u HC_RUN_ID bash "$LEDGER" append "" candidate '{"unit":"a.js"}'; then
      echo FAIL blank-id-fallback-nonzero-exit; exit 1
    fi
    local found; found="$(find .house-cleaning/runs -mindepth 1 -maxdepth 1 -type d \
      -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' 2>/dev/null)"
    [ -n "$found" ] || { echo FAIL blank-id-no-timestamp-dir; exit 1; }
  ) || exit 1; rm -rf "$tmp"; echo "ok: blank-id-fallback"
}

# T1 follow-up (review fix): a future reordering of init() (mkdir before validate) could
# silently reintroduce the traversal bug undetected — no existing test pinned that
# ordering directly. For each unsafe run id, `init` must refuse (exit != 0) AND must not
# have created ANY filesystem entry as a side effect first — checked two ways: (a) a
# whole-tree top-level snapshot (excluding .git) taken once before the loop must be
# byte-identical after every rejected attempt, and (b) the concrete historical escape
# target for '../../etc' (a mkdir -p of ".house-cleaning/runs/../../etc" resolves to
# "$d/etc", two levels above runs/) is explicitly asserted absent.
test_init_refuses_unsafe_run_id_before_any_mkdir() {
  local d; d="$(mktemp -d)"; ( cd "$d" && git init -q )
  local baseline; baseline="$(cd "$d" && find . -mindepth 1 -not -path './.git*' -not -path './.git' | sort)"
  for bad in '../../etc' '/etc' '-rf' '.' '_foo' '_'; do
    if ( cd "$d" && bash "$LEDGER" init "$bad" scope sha ) 2>/dev/null; then
      fail "init accepted unsafe run id: '$bad'"
    fi
  done
  local after; after="$(cd "$d" && find . -mindepth 1 -not -path './.git*' -not -path './.git' | sort)"
  [ "$baseline" = "$after" ] || fail "init created filesystem entries for an unsafe run id before refusing (baseline vs after differ)"
  [ ! -e "$d/etc" ] || fail "init traversal escaped: '$d/etc' was created for run id '../../etc'"
  rm -rf "$d"
}
