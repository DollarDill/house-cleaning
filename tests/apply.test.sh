# tests/apply.test.sh — cull.sh APPLY verb suite (T3, new). Sourced by run-tests.sh; uses
# harness helpers/vars: fail, $LEDGER, $CULL, _mk_repo_on_branch. Each test_* function is
# discovered and invoked by run-tests.sh (see its _run_suite doc comment). Every test makes
# its own fixture repo via _mk_repo_on_branch and removes it with an explicit `rm -rf "$d"`
# as its last statement (matches tests/probe.test.sh convention).
#
# Fixture default oracle ("npm test" against a package.json whose test script is `echo ok`)
# is trivially green — deleting ANY file keeps it green. That is correct for the atomic-commit
# coverage below, but the RED-oracle HALT tests need a REAL red/green distinction, so those
# tests overwrite .house-cleaning/oracle to make the oracle depend on the file actually being
# applied (same technique as probe.test.sh's kept-live/ddmin tests).

# --- Step 1 (plan-literal, adapted to harness conventions): apply refuses without approval;
# an approved unit is deleted as exactly one atomic commit carrying the applied ledger line. ---

test_apply_refuses_unapproved_unit() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  local list; list="$(mktemp)"; printf 'dead.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply "$list" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "apply without a decision:approved record should refuse with exit 2 (got $rc)"
  ( cd "$d" && test -f dead.ts ) || fail "unapproved unit must be untouched"
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "refused apply must not commit"
  rm -rf "$d" "$list"
}

test_apply_approved_unit_atomic_commit() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  local list; list="$(mktemp)"; printf 'dead.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 decision '{"unit":"dead.ts","decision":"approved","by":"user"}'
    HC_RUN_ID=r1 bash "$CULL" apply "$list" )
  ( cd "$d" && test -f dead.ts ) && fail "approved unit was not deleted"
  local n; n="$( cd "$d" && git rev-list --count "$before"..HEAD )"
  [ "$n" = "1" ] || fail "expected exactly 1 atomic commit (got $n)"
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after apply"
  grep -q '"type":"applied"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "no applied record"
  grep -q '"unit":"dead.ts"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "applied record missing unit"
  # The applied ledger line must be committed WITH the deletion, not left dangling uncommitted.
  ( cd "$d" && git show --name-only HEAD | grep -q 'ledger.jsonl' ) || fail "applied ledger line not part of the atomic commit"
  ( cd "$d" && git show --name-only HEAD | grep -q '^dead.ts$' ) || fail "deletion not part of the atomic commit"
  rm -rf "$d" "$list"
}

# --- never-auto-delete boundary: ANY unapproved unit in the manifest refuses BEFORE deleting
# anything else in the manifest — including units that ARE approved (coordination point 1). ---

test_apply_refuses_all_before_deleting_when_any_unit_unapproved() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  local list; list="$(mktemp)"; printf 'dead.ts\na.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 decision '{"unit":"dead.ts","decision":"approved","by":"user"}' )
  # a.ts intentionally has NO approved decision record.
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply "$list" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "manifest with any unapproved unit must refuse with exit 2 (got $rc)"
  ( cd "$d" && test -f dead.ts ) || fail "the approved-but-co-listed unit must survive when a sibling unit is unapproved"
  ( cd "$d" && test -f a.ts ) || fail "the unapproved unit must survive"
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "refused apply must not commit"
  rm -rf "$d" "$list"
}

# --- RED-oracle apply HALTs and restores (coordination point 1): oracle overwritten to depend
# on the approved unit itself, so applying it genuinely breaks the oracle. ---

test_apply_red_oracle_restores_and_halts() {
  local d; d="$(_mk_repo_on_branch)"
  printf 'test -f a.ts\n' > "$d/.house-cleaning/oracle"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  local list; list="$(mktemp)"; printf 'a.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 decision '{"unit":"a.ts","decision":"approved","by":"user"}' )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply "$list" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "red-oracle apply should HALT with exit 3 (got $rc)"
  ( cd "$d" && test -f a.ts ) || fail "red-oracle apply must restore the deleted file"
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "red-oracle apply must not leave a commit"
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after red-oracle HALT"
  ( grep -q '"type":"applied"' "$d/.house-cleaning/runs/r1/ledger.jsonl" 2>/dev/null ) && fail "no applied record should be logged on a red (restored, never committed) unit"
  rm -rf "$d" "$list"
}

# --- apply guard chain still fires (v1 guards carried forward to the apply verb) ---

test_apply_refuses_target_not_tracked() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo stray > stray.ts )
  local list; list="$(mktemp)"; printf 'stray.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$(git rev-parse HEAD)" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 decision '{"unit":"stray.ts","decision":"approved","by":"user"}' )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply "$list" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "untracked target must refuse via apply (got $rc); use apply-untracked"
  ( cd "$d" && test -f stray.ts ) || fail "untracked target must be untouched"
  rm -rf "$d" "$list"
}

test_apply_refuses_missing_manifest() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply /no/such/manifest-file.$$ ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "apply with a missing manifest file should refuse with exit 2 (got $rc)"
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "missing-manifest apply must not commit"
  rm -rf "$d"
}

# --- apply-untracked: tar-archive BEFORE rm; ledger records the applied unit ---

test_apply_untracked_archives_before_rm_and_logs() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo "stray content" > stray.ts )
  local list; list="$(mktemp)"; printf 'stray.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$(git rev-parse HEAD)" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 decision '{"unit":"stray.ts","decision":"approved","by":"user"}'
    HC_RUN_ID=r1 bash "$CULL" apply-untracked "$list" )
  ( cd "$d" && test -f stray.ts ) && fail "approved untracked unit was not removed"
  local arch; arch="$(ls "$d"/.house-cleaning/untracked-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$arch" ] || fail "no untracked archive created"
  tar -tzf "$arch" | grep -q '^stray\.ts$' || fail "archive does not contain stray.ts"
  grep -q '"type":"applied"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "no applied record for untracked unit"
  grep -q '"unit":"stray.ts"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "applied record missing unit"
  rm -rf "$d" "$list"
}

test_apply_untracked_refuses_tracked_file() {
  local d; d="$(_mk_repo_on_branch)"
  local list; list="$(mktemp)"; printf 'a.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$(git rev-parse HEAD)" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 decision '{"unit":"a.ts","decision":"approved","by":"user"}' )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply-untracked "$list" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "apply-untracked must refuse a tracked file (got $rc); use apply"
  ( cd "$d" && test -f a.ts ) || fail "tracked file must be untouched"
  rm -rf "$d" "$list"
}

test_apply_untracked_refuses_unapproved_unit() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo "stray content" > stray.ts )
  local list; list="$(mktemp)"; printf 'stray.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$(git rev-parse HEAD)" >/dev/null )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply-untracked "$list" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "apply-untracked without approval should refuse with exit 2 (got $rc)"
  ( cd "$d" && test -f stray.ts ) || fail "unapproved untracked unit must be untouched"
  rm -rf "$d" "$list"
}

# --- RED-oracle apply-untracked HALTs and restores from the archive (coordination point 1) ---

test_apply_untracked_red_oracle_restores_from_archive() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo "stray content" > stray.ts )
  printf 'test -f stray.ts\n' > "$d/.house-cleaning/oracle"
  local list; list="$(mktemp)"; printf 'stray.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$(git rev-parse HEAD)" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 decision '{"unit":"stray.ts","decision":"approved","by":"user"}' )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply-untracked "$list" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "red-oracle apply-untracked should HALT with exit 3 (got $rc)"
  ( cd "$d" && test -f stray.ts ) || fail "red-oracle apply-untracked must restore from the archive"
  [ "$(cat "$d/stray.ts")" = "stray content" ] || fail "restored stray.ts content mismatch"
  rm -rf "$d" "$list"
}
