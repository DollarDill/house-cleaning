# tests/persist.test.sh — ledger.sh `checkpoint` + `persist-base` + HC_LEDGER_MODE seam
# (T5). Sourced by run-tests.sh; uses harness helpers/vars: fail, $LEDGER,
# _mk_repo_on_branch. Each test_* function is discovered and invoked by run-tests.sh.
# Cleanup convention matches tests/ledger.test.sh: explicit `rm -rf "$d"` as the last
# statement, no RETURN trap (see ledger.test.sh header comment for why).
#
# Critical coordination point (see plan Task 5 + task brief): the ledger files under
# .house-cleaning/runs/<run_id>/ live only in commits on the house-cleaning branch. A
# naive `git checkout <base>; git add ...; git commit` finds nothing once HEAD is on
# <base>, because tracked-only-on-source files are removed by the branch switch. These
# tests assert the ACTUAL post-transfer state (reading the file from the base branch,
# asserting the persist commit's diff, and asserting HEAD's return) rather than trusting
# a zero exit code alone.

test_checkpoint_commits_ledger_on_current_branch() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init r1 . x >/dev/null
    HC_LEDGER_MODE=committed bash "$LEDGER" append r1 probe '{"unit":"a.ts","verdict":"kept-live"}'
    HC_LEDGER_MODE=committed bash "$LEDGER" checkpoint r1 )
  local cur; cur="$( cd "$d" && git rev-parse --abbrev-ref HEAD )"
  [ "$cur" = "house-cleaning/test" ] || fail "checkpoint must not change the current branch (on '$cur')"
  ( cd "$d" && git show HEAD --stat | grep -q "ledger checkpoint" ) \
    || fail "checkpoint did not create a 'ledger checkpoint' commit on the current branch"
  ( cd "$d" && git show HEAD:.house-cleaning/runs/r1/ledger.jsonl >/dev/null 2>&1 ) \
    || fail "checkpoint commit does not contain the run's ledger file"
  rm -rf "$d"
}

# The money test: read the ledger file FROM the base branch after persist-base, proving
# the transfer actually landed the content there (not just that the command exited 0).
test_persist_base_lands_file_on_base() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init r1 . x >/dev/null
    HC_LEDGER_MODE=committed bash "$LEDGER" append r1 probe '{"unit":"a.ts","verdict":"provably-dead"}'
    HC_LEDGER_MODE=committed bash "$LEDGER" persist-base main r1 )
  local content
  content="$( cd "$d" && git show "main:.house-cleaning/runs/r1/ledger.jsonl" 2>&1 )" \
    || fail "persist-base did not land the ledger file on base (git show failed: $content)"
  echo "$content" | grep -q '"unit":"a.ts"' || fail "ledger file on base is missing the appended record"
  rm -rf "$d"
}

test_persist_base_is_additive_only() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init r1 . x >/dev/null
    HC_LEDGER_MODE=committed bash "$LEDGER" append r1 probe '{"unit":"a.ts","verdict":"provably-dead"}'
    HC_LEDGER_MODE=committed bash "$LEDGER" persist-base main r1 )
  local touched; touched="$( cd "$d" && git diff --name-only main~1 main )"
  echo "$touched" | grep -qvE '^\.house-cleaning/' \
    && fail "persist-base touched non-ledger paths on base: $touched"
  echo "$touched" | grep -qE '^\.house-cleaning/runs/r1/' \
    || fail "persist-base did not add the run dir to base (touched: $touched)"
  rm -rf "$d"
}

test_persist_base_round_trip_returns_to_hc_branch() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse --abbrev-ref HEAD )"
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init r1 . x >/dev/null
    HC_LEDGER_MODE=committed bash "$LEDGER" append r1 probe '{"unit":"a.ts","verdict":"provably-dead"}'
    HC_LEDGER_MODE=committed bash "$LEDGER" persist-base main r1 )
  local after; after="$( cd "$d" && git rev-parse --abbrev-ref HEAD )"
  [ "$after" = "$before" ] || fail "persist-base left HEAD on '$after' instead of returning to '$before'"
  # And the house-cleaning branch's own history must be untouched by the persist commit
  # (the persist commit belongs to base, not to the house-cleaning branch).
  ( cd "$d" && git log --oneline "$before" | grep -q "audit history" ) \
    && fail "persist commit leaked onto the house-cleaning branch's own history"
  rm -rf "$d"
}

test_persist_base_second_call_is_idempotent() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" init r1 . x >/dev/null
    HC_LEDGER_MODE=committed bash "$LEDGER" append r1 probe '{"unit":"a.ts","verdict":"provably-dead"}'
    HC_LEDGER_MODE=committed bash "$LEDGER" persist-base main r1 )
  local after_first; after_first="$( cd "$d" && git rev-parse main )"
  ( cd "$d" && HC_LEDGER_MODE=committed bash "$LEDGER" persist-base main r1 ) \
    || fail "second persist-base call must not error (idempotent no-op expected)"
  local after_second; after_second="$( cd "$d" && git rev-parse main )"
  [ "$after_first" = "$after_second" ] || fail "second persist-base call created an unnecessary empty commit on base"
  local cur; cur="$( cd "$d" && git rev-parse --abbrev-ref HEAD )"
  [ "$cur" = "house-cleaning/test" ] || fail "second persist-base call left HEAD on '$cur'"
  rm -rf "$d"
}

test_local_mode_checkpoint_and_persist_are_noop_and_gitignored() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse main )"
  ( cd "$d" && HC_LEDGER_MODE=local bash "$LEDGER" init r1 . x >/dev/null
    HC_LEDGER_MODE=local bash "$LEDGER" append r1 probe '{"unit":"a.ts","verdict":"provably-dead"}'
    HC_LEDGER_MODE=local bash "$LEDGER" checkpoint r1
    HC_LEDGER_MODE=local bash "$LEDGER" persist-base main r1 )
  [ "$before" = "$( cd "$d" && git rev-parse main )" ] || fail "local mode must not commit to base"
  ( cd "$d" && [ -f .house-cleaning/runs/r1/ledger.jsonl ] ) \
    || fail "local mode: run dir should still exist on disk (init still writes it)"
  ( cd "$d" && git ls-files --error-unmatch .house-cleaning/runs/r1/ledger.jsonl >/dev/null 2>&1 ) \
    && fail "local mode: run dir should remain untracked (checkpoint must be a no-op, not git add)"
  ( cd "$d" && grep -qxF '.house-cleaning/' .git/info/exclude ) \
    || fail "local mode must gitignore .house-cleaning/ via .git/info/exclude"
  rm -rf "$d"
}
