# tests/oracle.test.sh — oracle.sh suite (v1, carried forward). Sourced by run-tests.sh;
# uses harness helpers/vars: fail, ok, make_fixture, $TMP, $SCRIPTS.

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
