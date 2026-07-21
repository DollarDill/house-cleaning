# tests/probe.test.sh — cull.sh PROBE verb suite (T2, new). Sourced by run-tests.sh; uses
# harness helpers/vars: fail, $LEDGER, $CULL, _mk_repo_on_branch. Each test_* function is
# discovered and invoked by run-tests.sh (see its _run_suite doc comment). Every test makes
# its own fixture repo via _mk_repo_on_branch and removes it with an explicit `rm -rf "$d"`
# as its last statement (see tests/ledger.test.sh's header comment for why NOT a RETURN trap).
#
# Fixture default oracle ("npm test" against a package.json whose test script is `echo ok`)
# is trivially green — deleting ANY file keeps it green. That is correct for provably-dead
# and probe-never-commits coverage below, but a "kept-live" / ddmin-isolates-live-member test
# needs a REAL red/green distinction, so those tests overwrite .house-cleaning/oracle to make
# the oracle depend on the file actually being probed (documented per-test below).

# --- Step 1 (plan-literal): probe never commits/mutates; provably-dead is logged ---

test_probe_file_never_commits_and_reverts() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe file dead.ts HIGH )
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "probe created a commit"
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after probe"
  ( cd "$d" && test -f dead.ts ) || fail "probe did not revert the deletion"
  grep -q '"verdict":"provably-dead"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "no provably-dead verdict logged"
  rm -rf "$d"
}

test_probe_refuses_target_inside_ledger_dir() {
  local d; d="$(_mk_repo_on_branch)"
  if ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
       HC_RUN_ID=r1 bash "$CULL" probe file .house-cleaning/runs/r1/ledger.jsonl ) 2>/dev/null; then
    fail "probe accepted a target inside .house-cleaning/"
  fi
  rm -rf "$d"
}

# --- Kept-live coverage (coordination point 1): oracle overwritten to depend on the LIVE
# file, so deleting it goes genuinely red and deleting the dead file stays genuinely green. ---

test_probe_file_kept_live_reverts_and_logs() {
  local d; d="$(_mk_repo_on_branch)"
  printf 'test -f a.ts\n' > "$d/.house-cleaning/oracle"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe file a.ts HIGH ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "probe of a live file should return 1 (got $rc)"
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "kept-live probe created a commit"
  ( cd "$d" && test -f a.ts ) || fail "kept-live probe did not restore a.ts"
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after kept-live probe"
  grep -q '"verdict":"kept-live"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "no kept-live verdict logged"
  grep -q '"oracle":"red"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "kept-live verdict missing oracle:red"
  rm -rf "$d"
}

# --- region granularity ---

test_probe_region_provably_dead() {
  local d; d="$(_mk_repo_on_branch)"
  local before_content; before_content="$(cat "$d/dead.ts")"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe region dead.ts 1 1 HIGH )
  [ "$(cat "$d/dead.ts")" = "$before_content" ] || fail "region probe did not restore dead.ts byte-identical"
  grep -q '"unit":"dead.ts:1-1"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "region unit not logged as path:start-end"
  grep -q '"granularity":"region"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "region granularity not logged"
  grep -q '"verdict":"provably-dead"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "region probe should be provably-dead under trivial oracle"
  rm -rf "$d"
}

# --- bisect: base case (no recursion needed) ---

test_probe_bisect_dead_region_no_recursion() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe bisect dead.ts 1 1 HIGH )
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after bisect"
  grep -q '"verdict":"provably-dead"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "bisect base case should log provably-dead"
  rm -rf "$d"
}

# --- bisect: recursive isolation of a live line from a dead line in the same file ---

test_probe_bisect_isolates_live_from_dead() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" \
      && printf 'const DEAD = 1; // dead\nexport const LIVE = 1;\n' > combo.ts \
      && git add combo.ts && git commit -qm "add combo.ts" )
  printf "grep -q 'LIVE = 1' combo.ts\n" > "$d/.house-cleaning/oracle"
  local before_content; before_content="$(cat "$d/combo.ts")"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe bisect combo.ts 1 2 HIGH ) || true
  [ "$(cat "$d/combo.ts")" = "$before_content" ] || fail "bisect did not restore combo.ts byte-identical"
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after recursive bisect"
  grep -q '"unit":"combo.ts:1-1".*"verdict":"provably-dead"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "dead line (1-1) should be provably-dead"
  grep -q '"unit":"combo.ts:2-2".*"verdict":"kept-live"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "live line (2-2) should be kept-live"
  rm -rf "$d"
}

# --- batch: all-green ⇒ every member logged provably-dead, in one probe (no commit) ---

test_probe_batch_all_green_logs_provably_dead_for_all() {
  local d; d="$(_mk_repo_on_branch)"
  # List file lives OUTSIDE the repo (matches v1's /tmp-list convention) so it never shows up
  # as an untracked stray in the fixture's own working tree.
  local list; list="$(mktemp)"; printf 'dead.ts\na.ts\n' > "$list"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe batch "$list" HIGH )
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "green batch probe created a commit"
  ( cd "$d" && test -f dead.ts && test -f a.ts ) || fail "green batch probe did not restore all members"
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after green batch"
  # `grep -c` exits 1 (not 0) when the count is zero; under `set -e` a bare assignment from a
  # failing command substitution aborts the whole suite BEFORE the `fail` check below ever
  # runs (verified: this is exactly what happens without the `|| true`) — so guard it.
  local n; n="$(grep -c '"verdict":"provably-dead"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || true)"
  [ "$n" -eq 2 ] || fail "expected 2 provably-dead records, got $n"
  rm -rf "$d" "$list"
}

# --- batch: partial red ⇒ ddmin isolates the live member as kept-live, dead member stays
# provably-dead (coordination point 1: oracle overwritten to depend on a.ts specifically). ---

test_probe_batch_red_ddmin_isolates_live_member() {
  local d; d="$(_mk_repo_on_branch)"
  printf 'test -f a.ts\n' > "$d/.house-cleaning/oracle"
  local list; list="$(mktemp)"; printf 'dead.ts\na.ts\n' > "$list"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$before" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe batch "$list" HIGH )
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "ddmin batch probe created a commit"
  ( cd "$d" && test -f dead.ts && test -f a.ts ) || fail "ddmin batch probe did not restore all members"
  ( cd "$d" && git status --porcelain -- ':(exclude).house-cleaning/' | grep -q . ) && fail "tree dirty after ddmin batch"
  grep -q '"unit":"dead.ts".*"verdict":"provably-dead"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "dead.ts should be isolated as provably-dead"
  grep -q '"unit":"a.ts".*"verdict":"kept-live"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "a.ts should be isolated as kept-live"
  rm -rf "$d" "$list"
}

# --- guard chain still fires under the probe verb (v1 guards carried forward) ---

test_probe_refuses_on_non_house_cleaning_branch() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && git checkout -q main )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" probe file dead.ts HIGH ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "should refuse off house-cleaning/* branch (got $rc)"
  ( cd "$d" && test -f dead.ts ) || fail "dead.ts must be untouched on refusal"
  rm -rf "$d"
}

test_probe_refuses_dirty_tree_outside_ledger_dir() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo dirty >> a.ts )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" probe file dead.ts HIGH ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "should refuse on dirty tracked file outside .house-cleaning/ (got $rc)"
  ( cd "$d" && test -f dead.ts ) || fail "dead.ts must be untouched on refusal"
  rm -rf "$d"
}

test_probe_clean_tree_guard_excludes_house_cleaning_dir() {
  local d; d="$(_mk_repo_on_branch)"
  # .house-cleaning/oracle is a TRACKED file (committed by _mk_repo_on_branch); dirtying it
  # must NOT trip the clean-tree guard — only ':(exclude).house-cleaning/' is checked.
  ( cd "$d" && printf '# note\n' >> .house-cleaning/oracle )
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe file dead.ts HIGH )
  grep -q '"verdict":"provably-dead"' "$d/.house-cleaning/runs/r1/ledger.jsonl" || fail "probe should have proceeded despite a dirty (tracked) .house-cleaning/ file"
  rm -rf "$d"
}

test_probe_path_guard_blocks_symlink_escape() {
  local d; d="$(_mk_repo_on_branch)"
  local outside; outside="$(mktemp -d)"
  echo secret > "$outside/secret.txt"
  ( cd "$d" && ln -s "$outside" evil-link && git add evil-link && git commit -qm "add symlink" )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" probe file evil-link/secret.txt ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "symlink escape must refuse (got $rc)"
  [ -f "$outside/secret.txt" ] || fail "outside file must survive"
  rm -rf "$d" "$outside"
}

test_probe_keep_guard_refuses_keep_listed_path() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo "dead.ts" > .house-cleaning/keep )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" probe file dead.ts ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "keep-list match must refuse (got $rc)"
  ( cd "$d" && test -f dead.ts ) || fail "keep-listed file must be untouched"
  rm -rf "$d"
}

test_probe_secrets_guard_refuses_secret_shaped_path() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo "API_KEY=x" > app.env )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" probe file app.env ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "secret-shaped file must refuse (got $rc)"
  ( cd "$d" && test -f app.env ) || fail "secret-shaped file must be untouched"
  rm -rf "$d"
}

test_probe_tracked_guard_refuses_untracked_target() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && echo stray > stray.ts )
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" probe file stray.ts ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "untracked target must refuse (got $rc)"
  ( cd "$d" && test -f stray.ts ) || fail "untracked target must be untouched"
  rm -rf "$d"
}

# --- Task 3: cull.sh resolves the run id via ledger stickiness — no HC_RUN_ID
# export required across separate shell invocations. ---

test_probe_resolves_run_id_via_stickiness_no_env_export() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  # Shell A: init only (writes .house-cleaning/current-run). No HC_RUN_ID exported.
  ( cd "$d" && env -u HC_RUN_ID bash "$LEDGER" init sticky-run . "$before" >/dev/null )
  [ "$(cat "$d/.house-cleaning/current-run")" = "sticky-run" ] || fail "init did not write current-run"
  # Shell B: FRESH shell, HC_RUN_ID unset entirely — cull.sh must resolve the run id from
  # .house-cleaning/current-run via ledger.sh resolve-run-id, not from the environment.
  ( cd "$d" && env -u HC_RUN_ID bash "$CULL" probe file dead.ts HIGH )
  grep -q '"verdict":"provably-dead"' "$d/.house-cleaning/runs/sticky-run/ledger.jsonl" \
    || fail "probe record did not land in the run resolved via stickiness (no HC_RUN_ID export)"
  rm -rf "$d"
}

test_probe_still_refuses_off_house_cleaning_branch_with_no_env_run_id() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && git checkout -q main )
  local rc=0
  ( cd "$d" && env -u HC_RUN_ID bash "$CULL" probe file dead.ts HIGH ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "should still refuse off house-cleaning/* branch with no HC_RUN_ID set (got $rc)"
  ( cd "$d" && test -f dead.ts ) || fail "dead.ts must be untouched on refusal"
  rm -rf "$d"
}

# --- led() must be fail-closed: an unresolved/rejected run id must refuse the WHOLE probe,
# never fall through into append()'s own permissive lazy-default (which would otherwise
# fabricate a fresh timestamp-id "orphan" run and silently succeed — misattributing the
# ledger record instead of refusing). restore() already ran before led() in every probe
# path, so dead.ts is untouched either way; the assertion here is about the EXIT CODE and
# the absence of a fabricated run dir, not file safety. ---

test_probe_refuses_when_no_active_run_and_creates_no_orphan() {
  local d; d="$(_mk_repo_on_branch)"
  # No `ledger.sh init` at all: no .house-cleaning/current-run, HC_RUN_ID unset.
  local rc=0
  ( cd "$d" && env -u HC_RUN_ID bash "$CULL" probe file dead.ts HIGH ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "probe with no active run (no init, no HC_RUN_ID) must refuse (got 0)"
  [ -d "$d/.house-cleaning/runs" ] && fail "probe with no active run must not fabricate an orphan runs/ dir"
  ( cd "$d" && test -f dead.ts ) || fail "dead.ts must be untouched"
  rm -rf "$d"
}

test_probe_refuses_rejected_env_run_id_and_creates_no_orphan() {
  local d; d="$(_mk_repo_on_branch)"
  local rc=0
  ( cd "$d" && HC_RUN_ID='../../etc' bash "$CULL" probe file dead.ts HIGH ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "probe with a rejected HC_RUN_ID ('../../etc') must refuse (got 0)"
  [ -d "$d/.house-cleaning/runs" ] && fail "probe with a rejected HC_RUN_ID must not fabricate an orphan runs/ dir"
  ( cd "$d" && test -f dead.ts ) || fail "dead.ts must be untouched"
  rm -rf "$d"
}

# --- apply is Task 3: confirm the stub fails cleanly and does not mutate anything ---

test_probe_apply_stub_fails_cleanly() {
  local d; d="$(_mk_repo_on_branch)"
  local before; before="$( cd "$d" && git rev-parse HEAD )"
  local rc=0
  ( cd "$d" && HC_RUN_ID=r1 bash "$CULL" apply some-manifest.json ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "apply stub should exit 2 (got $rc)"
  local after; after="$( cd "$d" && git rev-parse HEAD )"
  [ "$before" = "$after" ] || fail "apply stub must not commit"
  rm -rf "$d"
}
