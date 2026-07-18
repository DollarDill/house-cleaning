# tests/resumption.test.sh — ledger.sh resumption/coverage suite (T4, new). Sourced by
# run-tests.sh; uses harness helpers/vars: fail, $LEDGER, $CULL, _mk_repo_on_branch. Each
# test_* function is discovered and invoked by run-tests.sh (see its _run_suite doc comment).
# Every test makes its own fixture repo via _mk_repo_on_branch (or a bare `mktemp -d` + `git
# init` for changed-since-only tests) and removes it with an explicit `rm -rf "$d"` as its
# last statement (matches tests/ledger.test.sh / tests/probe.test.sh convention).
#
# Covers plan Task 4 (changed-since, coverage-summary) plus the brief's items 3 (git_sha on
# ALL probe records — file/region/bisect/batch) and 4 (coverage-view --since sha-aware
# invalidation).

# --- changed-since (plan Step 1, adapted) ---

test_changed_since_lists_changed_files() {
  local d; d="$(_mk_repo_on_branch)"
  local s1; s1="$( cd "$d" && git rev-parse HEAD )"
  ( cd "$d" && echo "// changed" >> a.ts && git commit -aqm "touch a.ts" )
  local changed; changed="$( cd "$d" && bash "$LEDGER" changed-since "$s1" )"
  echo "$changed" | grep -qx "a.ts" || fail "changed-since should list a.ts"
  rm -rf "$d"
}

# Exit-code caution (brief): verify changed-since returns 0 even when nothing changed, and
# prints nothing — don't trust the idiom without a test.
test_changed_since_no_changes_returns_empty_exit_0() {
  local d; d="$(_mk_repo_on_branch)"
  local s1; s1="$( cd "$d" && git rev-parse HEAD )"
  local out rc=0
  out="$( cd "$d" && bash "$LEDGER" changed-since "$s1" )" || rc=$?
  [ "$rc" -eq 0 ] || fail "changed-since should exit 0 when nothing changed (got $rc)"
  [ -z "$out" ] || fail "changed-since should print nothing when nothing changed (got: $out)"
  rm -rf "$d"
}

# --- coverage-summary (plan Step 5, literal) ---

test_coverage_summary_never_done_when_partial() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 candidate '{"unit":"a.ts","granularity":"file","evidence":["knip"],"tier":"HIGH","source":"knip"}'
    HC_RUN_ID=r1 bash "$LEDGER" append r1 candidate '{"unit":"b.ts","granularity":"file","evidence":["knip"],"tier":"HIGH","source":"knip"}'
    HC_RUN_ID=r1 bash "$LEDGER" append r1 probe '{"unit":"a.ts","granularity":"file","verdict":"provably-dead"}' )
  local out; out="$( cd "$d" && bash "$LEDGER" coverage-summary r1 )"
  echo "$out" | grep -q "1 uncovered" || fail "coverage-summary miscount: $out"
  echo "$out" | grep -qi "run again" || fail "partial coverage must prompt continuation"
  rm -rf "$d"
}

test_coverage_summary_reports_zero_uncovered_when_fully_swept() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 candidate '{"unit":"a.ts","granularity":"file","evidence":["knip"],"tier":"HIGH","source":"knip"}'
    HC_RUN_ID=r1 bash "$LEDGER" append r1 probe '{"unit":"a.ts","granularity":"file","verdict":"provably-dead"}' )
  local out; out="$( cd "$d" && bash "$LEDGER" coverage-summary r1 )"
  echo "$out" | grep -q "0 uncovered" || fail "coverage-summary should report 0 uncovered when fully swept: $out"
  echo "$out" | grep -qi "run again" && fail "must not prompt continuation when fully covered: $out"
  rm -rf "$d"
}

# Regression (review finding, cc-eval-vmk3): coverage-summary must count by CANDIDATE-UNIT
# MEMBERSHIP, not scalar (candidate-records - probe-records) subtraction — probe_bisect/_ddmin
# emit MULTIPLE leaf probe records for a SINGLE candidate (bisection splits one region/batch
# into several leaf verdicts), so raw subtraction under-reports uncovered work. Reproduces the
# reviewer's exact scenario: 2 candidates (a region that gets bisected into 2 leaf records, and
# a file that is never probed at all); scalar subtraction would wrongly print "0 uncovered"
# (2 candidate records - 2 probe records = 0) even though other.ts was never examined — a false
# full-coverage report, exactly what "scale honesty" forbids.
test_coverage_summary_counts_by_candidate_membership_not_record_count() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" \
      && printf 'const DEAD = 1; // dead\nexport const LIVE = 1;\n' > combo.ts \
      && git add combo.ts && git commit -qm "add combo.ts" )
  printf "grep -q 'LIVE = 1' combo.ts\n" > "$d/.house-cleaning/oracle"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 candidate '{"unit":"combo.ts:1-2","granularity":"region","evidence":["dce"],"tier":"HIGH","source":"dce"}'
    HC_RUN_ID=r1 bash "$LEDGER" append r1 candidate '{"unit":"other.ts","granularity":"file","evidence":["knip"],"tier":"HIGH","source":"knip"}'
    # Whole-region oracle check [1,2] is RED (removing both lines removes the live one too) ⇒
    # probe_bisect recurses into TWO leaf records (combo.ts:1-1, combo.ts:2-2) for this ONE
    # candidate — the multi-record-per-candidate case the fix must handle.
    HC_RUN_ID=r1 bash "$CULL" probe bisect combo.ts 1 2 HIGH ) || true
  local n; n="$( cd "$d" && jq -rs '[.[]|select(.type=="probe")]|length' .house-cleaning/runs/r1/ledger.jsonl )"
  [ "$n" -ge 2 ] || fail "setup invariant broken: expected >=2 leaf probe records for 1 candidate, got $n"
  local out; out="$( cd "$d" && bash "$LEDGER" coverage-summary r1 )"
  echo "$out" | grep -q "1 uncovered" || fail "other.ts was never probed — expected 1 uncovered (multi-record bisect must not be mistaken for full coverage): $out"
  echo "$out" | grep -qi "run again" || fail "partial coverage must prompt continuation: $out"
  rm -rf "$d"
}

# Lock-in: the simple 1-candidate/1-probe exact-match case (whole-file candidate swept by a
# whole-file probe) must keep working under the unit-membership redesign.
test_coverage_summary_file_candidate_swept_by_exact_whole_file_probe() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 candidate '{"unit":"a.ts","granularity":"file","evidence":["knip"],"tier":"HIGH","source":"knip"}'
    HC_RUN_ID=r1 bash "$LEDGER" append r1 probe '{"unit":"a.ts","granularity":"file","verdict":"kept-live"}' )
  local out; out="$( cd "$d" && bash "$LEDGER" coverage-summary r1 )"
  echo "$out" | grep -q "swept 1 of 1" || fail "exact whole-file match should count as swept: $out"
  echo "$out" | grep -q "0 uncovered" || fail "exact whole-file match should leave 0 uncovered: $out"
  rm -rf "$d"
}

# --- git_sha on ALL probe records (brief item 3): bisect and batch previously omitted it ---

test_probe_bisect_records_carry_git_sha() {
  local d; d="$(_mk_repo_on_branch)"
  local s1; s1="$( cd "$d" && git rev-parse HEAD )"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$s1" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe bisect dead.ts 1 1 HIGH )
  local gs; gs="$( cd "$d" && jq -rs '[.[]|select(.type=="probe")][0].git_sha // ""' .house-cleaning/runs/r1/ledger.jsonl )"
  [ -n "$gs" ] || fail "probe bisect record missing git_sha"
  [ "$gs" = "$s1" ] || fail "probe bisect git_sha should be the sha at probe time (got '$gs', want '$s1')"
  rm -rf "$d"
}

test_probe_bisect_kept_live_record_carries_git_sha() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" \
      && printf 'const DEAD = 1; // dead\nexport const LIVE = 1;\n' > combo.ts \
      && git add combo.ts && git commit -qm "add combo.ts" )
  printf "grep -q 'LIVE = 1' combo.ts\n" > "$d/.house-cleaning/oracle"
  local s1; s1="$( cd "$d" && git rev-parse HEAD )"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$s1" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe bisect combo.ts 1 2 HIGH ) || true
  local gs; gs="$( cd "$d" && jq -rs '[.[]|select(.type=="probe" and .verdict=="kept-live")][0].git_sha // ""' .house-cleaning/runs/r1/ledger.jsonl )"
  [ -n "$gs" ] || fail "bisect kept-live record missing git_sha"
  rm -rf "$d"
}

test_probe_batch_provably_dead_records_carry_git_sha() {
  local d; d="$(_mk_repo_on_branch)"
  local s1; s1="$( cd "$d" && git rev-parse HEAD )"
  local list; list="$(mktemp)"; printf 'dead.ts\na.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$s1" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe batch "$list" HIGH )
  local n; n="$( cd "$d" && jq -rs '[.[]|select(.type=="probe" and (.git_sha // "")!="")]|length' .house-cleaning/runs/r1/ledger.jsonl )"
  [ "$n" -eq 2 ] || fail "expected 2 batch probe records with non-empty git_sha, got $n"
  rm -rf "$d" "$list"
}

test_probe_batch_kept_live_record_carries_git_sha() {
  local d; d="$(_mk_repo_on_branch)"
  printf 'test -f a.ts\n' > "$d/.house-cleaning/oracle"
  local s1; s1="$( cd "$d" && git rev-parse HEAD )"
  local list; list="$(mktemp)"; printf 'dead.ts\na.ts\n' > "$list"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$s1" >/dev/null
    HC_RUN_ID=r1 bash "$CULL" probe batch "$list" HIGH )
  local gs; gs="$( cd "$d" && jq -rs '[.[]|select(.type=="probe" and .unit=="a.ts")][0].git_sha // ""' .house-cleaning/runs/r1/ledger.jsonl )"
  [ -n "$gs" ] || fail "kept-live batch record (a.ts) missing git_sha"
  rm -rf "$d" "$list"
}

# --- coverage-view --since (brief item 4): sha-aware invalidation on resume ---

test_coverage_view_since_drops_changed_unit_keeps_unchanged() {
  local d; d="$(_mk_repo_on_branch)"
  local s1; s1="$( cd "$d" && git rev-parse HEAD )"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . "$s1" >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 probe "$(jq -nc --arg g "$s1" '{unit:"a.ts",granularity:"file",verdict:"kept-live",git_sha:$g}')"
    HC_RUN_ID=r1 bash "$LEDGER" append r1 probe "$(jq -nc --arg g "$s1" '{unit:"dead.ts",granularity:"file",verdict:"provably-dead",git_sha:$g}')"
    echo "// changed" >> a.ts && git commit -aqm "touch a.ts" )
  local view; view="$( cd "$d" && bash "$LEDGER" coverage-view --since )"
  echo "$view" | jq -e 'has("a.ts")' >/dev/null && fail "changed unit a.ts should be dropped from coverage-view --since: $view"
  echo "$view" | jq -e 'has("dead.ts")' >/dev/null || fail "unchanged unit dead.ts should still be present: $view"
  rm -rf "$d"
}

test_coverage_view_since_omits_units_missing_git_sha() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 probe '{"unit":"a.ts","granularity":"file","verdict":"kept-live"}' )
  local view; view="$( cd "$d" && bash "$LEDGER" coverage-view --since )"
  echo "$view" | jq -e 'has("a.ts")' >/dev/null && fail "unit with no recorded git_sha must be omitted from --since view (can't confirm freshness): $view"
  rm -rf "$d"
}

test_coverage_view_since_omits_units_with_malformed_git_sha() {
  local d; d="$(_mk_repo_on_branch)"
  ( cd "$d" && HC_RUN_ID=r1 bash "$LEDGER" init r1 . x >/dev/null
    HC_RUN_ID=r1 bash "$LEDGER" append r1 probe '{"unit":"a.ts","granularity":"file","verdict":"kept-live","git_sha":"not-a-real-revision-1234"}' )
  local view; view="$( cd "$d" && bash "$LEDGER" coverage-view --since )"
  echo "$view" | jq -e 'has("a.ts")' >/dev/null && fail "unit with an unresolvable/malformed git_sha must be omitted (fail closed — can't confirm freshness): $view"
  rm -rf "$d"
}

test_coverage_view_since_empty_when_no_runs() {
  local d; d="$(_mk_repo_on_branch)"
  local view; view="$( cd "$d" && bash "$LEDGER" coverage-view --since )"
  [ "$view" = "{}" ] || fail "coverage-view --since should be {} with no runs (got $view)"
  rm -rf "$d"
}
