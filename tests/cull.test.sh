# tests/cull.test.sh — cull.sh core + extended suite (v1, carried forward). Sourced by
# run-tests.sh; uses harness helpers/vars: fail, ok, make_fixture, $TMP, $SCRIPTS.

# --- cull.sh core tests ---
make_fixture
"$SCRIPTS/cull.sh" file dead-module.sh HIGH >/dev/null
[ ! -f dead-module.sh ] || fail "dead file should be deleted"
git log --oneline -1 | grep -q "house-cleaning: dead-module.sh" || fail "atomic commit missing"
awk -F'\t' '$2=="file" && $3=="dead-module.sh" && $5=="deleted"' .house-cleaning/verdicts.log | grep -q . || fail "deleted verdict not logged"
ok "cull file deletes dead file"

"$SCRIPTS/cull.sh" file check.sh HIGH >/dev/null || true
[ -f check.sh ] || fail "live file should be restored"
awk -F'\t' '$2=="file" && $3=="check.sh" && $5=="kept-live"' .house-cleaning/verdicts.log | grep -q . || fail "kept-live verdict not logged"
ok "cull file keeps live file"

make_fixture
before="$(cat lib.sh)"
"$SCRIPTS/cull.sh" region lib.sh 2 2 HIGH >/dev/null
grep -q "DEAD_VAR" lib.sh && fail "dead line should be gone"
ok "cull region deletes dead line"

make_fixture
"$SCRIPTS/cull.sh" region lib.sh 1 1 HIGH >/dev/null || true
[ "$(cat lib.sh)" = "$before" ] || fail "live-line file should be restored byte-identical"
ok "cull region keeps live line"

make_fixture
git checkout -q main
rc=0; "$SCRIPTS/cull.sh" file dead-module.sh >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "should refuse on main (got $rc)"
git checkout -q house-cleaning/test
echo dirty >> lib.sh
rc=0; "$SCRIPTS/cull.sh" file dead-module.sh >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "should refuse on dirty tree (got $rc)"
git checkout -q -- lib.sh
ok "cull guards refuse main/dirty"

make_fixture
mkdir -p "$TMP/outside"; echo secret > "$TMP/outside/secret.txt"
ln -s ../outside evil-link
git add evil-link; git commit -qm "add symlink"
rc=0; "$SCRIPTS/cull.sh" file evil-link/secret.txt >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "symlink escape must refuse (got $rc)"
[ -f "$TMP/outside/secret.txt" ] || fail "outside file must survive"
ok "path_guard blocks symlink escape"

make_fixture
echo stray > stray.sh
rc=0; "$SCRIPTS/cull.sh" file stray.sh >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "untracked target must refuse (got $rc)"
[ -f stray.sh ] || fail "untracked target must be untouched"
ok "tracked_guard refuses untracked targets"

make_fixture
echo junk > stray-junk.txt
"$SCRIPTS/cull.sh" file dead-module.sh HIGH >/dev/null
git show --name-only --format= HEAD | grep -q stray-junk && fail "untracked file must not be swept into cull commit"
git ls-files --others --exclude-standard | grep -q stray-junk.txt || fail "stray file should remain untracked"
git show --name-only --format= HEAD | grep -q '\.house-cleaning' && fail ".house-cleaning must never be committed"
ok "commit staging is scoped; no untracked sweep"

echo "ALL CULL CORE TESTS PASSED"

# --- bisect / batch / untracked tests ---
make_fixture
"$SCRIPTS/cull.sh" bisect lib.sh 1 2 HIGH >/dev/null || true
grep -q "DEAD_VAR" lib.sh && fail "bisect should delete the dead line"
grep -q "live()" lib.sh || fail "bisect must keep the live line"
"$SCRIPTS/oracle.sh" run >/dev/null || fail "post-bisect oracle must be green"
ok "bisect isolates dead from live"

make_fixture
printf '%s\n' dead-module.sh dead-module2.sh > /tmp/hc-batch-$$.txt
n_before="$(git rev-list --count HEAD)"
"$SCRIPTS/cull.sh" batch /tmp/hc-batch-$$.txt HIGH >/dev/null
[ ! -f dead-module.sh ] || fail "batch should delete dead-module.sh"
[ ! -f dead-module2.sh ] || fail "batch should delete dead-module2.sh"
n_after="$(git rev-list --count HEAD)"
[ "$((n_after - n_before))" -eq 1 ] || fail "green batch must be ONE commit (got $((n_after - n_before)))"
ok "batch green = one commit"

make_fixture
printf '%s\n' dead-module.sh check.sh > /tmp/hc-batch-$$.txt
"$SCRIPTS/cull.sh" batch /tmp/hc-batch-$$.txt HIGH >/dev/null || true
[ ! -f dead-module.sh ] || fail "ddmin should still delete the dead member"
[ -f check.sh ] || fail "ddmin must keep the live member"
ok "batch red = ddmin isolates"
rm -f /tmp/hc-batch-$$.txt

make_fixture
echo junk > junk.txt
printf 'junk.txt\n' > /tmp/hc-untracked-$$.txt
"$SCRIPTS/cull.sh" untracked /tmp/hc-untracked-$$.txt >/dev/null
[ ! -f junk.txt ] || fail "untracked junk should be removed"
arch=""
for f in .house-cleaning/untracked-*.tar.gz; do arch="$f"; break; done
[ -n "$arch" ] || fail "archive file missing"
tar -tzf "$arch" | grep -q junk.txt || fail "archive must contain junk.txt"
ok "untracked archives before rm"
rm -f /tmp/hc-untracked-$$.txt

make_fixture
echo "dead-module.sh" > .house-cleaning/keep
rc=0; "$SCRIPTS/cull.sh" file dead-module.sh >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "keep-list match must refuse (got $rc)"
[ -f dead-module.sh ] || fail "keep-listed file must be untouched"
ok "keep-list refuses by construction"

make_fixture
echo 'export NEEDED=1' > config.txt
cat > check.sh <<'CHK'
#!/usr/bin/env bash
[ -f config.txt ] || exit 1
out=$(bash -c '. ./lib.sh; live')
[ "$out" = "42" ]
CHK
git add check.sh; git commit -qm "check requires config.txt"
printf 'config.txt\n' > /tmp/hc-untracked-red-$$.txt
rc=0; "$SCRIPTS/cull.sh" untracked /tmp/hc-untracked-red-$$.txt >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "red untracked run must exit non-zero"
[ -f config.txt ] || fail "config.txt must be restored from archive"
awk -F'\t' '$2=="untracked" && $3=="config.txt" && $5=="restored"' .house-cleaning/verdicts.log | grep -q . || fail "per-path restored verdict not logged"
ok "untracked red path restores + logs per-path"
rm -f /tmp/hc-untracked-red-$$.txt

make_fixture
echo "API_KEY=x" > app.env
git add app.env; git commit -qm "add env"
rc=0; "$SCRIPTS/cull.sh" file app.env >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "secret-shaped file must refuse (got $rc)"
[ -f app.env ] || fail "secret-shaped file must be untouched"
ok "secrets_guard refuses secret-shaped paths"

echo "ALL CULL EXTENDED TESTS PASSED"
