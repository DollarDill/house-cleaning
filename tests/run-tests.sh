#!/usr/bin/env bash
set -euo pipefail
# Self-tests for house-cleaning scripts, run against a planted fixture project.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/skills/house-cleaning/scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# Fixture: tiny git project whose oracle is `bash check.sh`.
# Planted: dead-module.sh (dead file), lib.sh line 2 (dead line), lib.sh line 1 (live line).
make_fixture() {
  rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"; cd "$TMP/proj"
  git init -q -b main
  git config user.email test@test; git config user.name test
  printf 'live() { echo 42; }\nDEAD_VAR="unused sediment"\n' > lib.sh
  cat > check.sh <<'CHK'
#!/usr/bin/env bash
out=$(bash -c '. ./lib.sh; live')
[ "$out" = "42" ]
CHK
  printf 'totally_unreferenced() { echo never; }\n' > dead-module.sh
  printf 'also_unreferenced() { echo never; }\n' > dead-module2.sh
  git add -A; git commit -qm init
  git checkout -qb house-cleaning/test
  mkdir -p .house-cleaning
  echo "bash check.sh" > .house-cleaning/oracle
}

# --- oracle.sh tests ---
make_fixture
"$SCRIPTS/oracle.sh" run >/dev/null || fail "oracle green fixture should exit 0"
ok "oracle run green"

echo "false" > .house-cleaning/oracle
"$SCRIPTS/oracle.sh" run >/dev/null 2>&1 && fail "oracle red fixture should exit 1"
ok "oracle run red"

rm .house-cleaning/oracle
rc=0; "$SCRIPTS/oracle.sh" run >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "missing oracle file should exit 2 (got $rc)"
ok "oracle missing file"

make_fixture
echo "bash -c 'test -f .flaked || { touch .flaked; exit 1; }'" > .house-cleaning/oracle
rm -f .flaked
"$SCRIPTS/oracle.sh" run >/dev/null || fail "oracle flake fixture should exit 0 (retry should flip to green)"
awk -F'\t' 'NF==6 && $2=="flake" && $5=="flake"' .house-cleaning/verdicts.log | grep -q . || fail "flake should be logged with 6 tab-separated fields, kind=flake, verdict=flake"
ok "oracle flake retry treated green + logged"

cd "$TMP"; rm -rf det; mkdir det; cd det
printf '{ "scripts": { "test": "echo t", "build": "echo b" } }\n' > package.json
out="$("$SCRIPTS/oracle.sh" detect)"
echo "$out" | grep -q "npm run test" || fail "detect should propose npm run test"
echo "$out" | grep -q "npm run build" || fail "detect should propose npm run build"
ok "oracle detect package.json"

echo "ALL ORACLE TESTS PASSED"

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
[ ! -f dead-module.sh ] && [ ! -f dead-module2.sh ] || fail "batch should delete both dead files"
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

echo "ALL CULL EXTENDED TESTS PASSED"
