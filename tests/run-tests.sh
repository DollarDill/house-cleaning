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

echo "ALL CULL CORE TESTS PASSED"
