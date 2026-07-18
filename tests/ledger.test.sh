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
