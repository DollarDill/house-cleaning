#!/usr/bin/env bash
set -euo pipefail
# Shared test harness for house-cleaning scripts. Runs one or all tests/*.test.sh suites
# against planted fixture projects.
#   run-tests.sh            — run every suite (tests/*.test.sh), in file order.
#   run-tests.sh <suite>    — run exactly one suite (e.g. `run-tests.sh ledger` runs
#                             tests/ledger.test.sh only).
#
# Suite files come in two styles:
#   - flat (v1: oracle, cull) — assertions run top-to-bottom as a side effect of sourcing.
#   - test_* functions (ledger and later) — the harness discovers and calls every
#     function newly defined by sourcing the suite whose name starts with `test_`.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/skills/house-cleaning/scripts"
LEDGER="$SCRIPTS/ledger.sh"
CULL="$SCRIPTS/cull.sh"
ORACLE="$SCRIPTS/oracle.sh"
export LEDGER CULL ORACLE
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# Fixture: tiny git project whose oracle is `bash check.sh`. Shared by the v1 oracle/cull suites.
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

# Fixture: fresh git repo on a house-cleaning/* branch with one dead unit (dead.ts) and one
# live unit (a.ts) behind a trivially-green npm oracle. Shared by the ledger/probe/apply
# suites (T1+, per plan). Echoes the repo path on stdout: d="$(_mk_repo_on_branch)".
_mk_repo_on_branch() {
  local d; d="$(mktemp -d)"
  ( cd "$d" \
      && git init -q -b main \
      && git config user.email test@test \
      && git config user.name test \
      && printf 'export function dead(): number { return 0; }\n' > dead.ts \
      && printf 'export function a(): number { return 42; }\n' > a.ts \
      && printf '{ "name": "fixture", "scripts": { "test": "echo ok" } }\n' > package.json \
      && mkdir -p .house-cleaning \
      && echo "npm test" > .house-cleaning/oracle \
      && git add -A \
      && git commit -qm init \
      && git checkout -qb house-cleaning/test )
  echo "$d"
}

# Run one suite file. Flat-style suites (oracle/cull) execute their assertions as a side
# effect of `source`; function-style suites (ledger+) define test_* functions that this
# discovers (by diffing `declare -F` before/after the source) and calls in turn.
_run_suite() {
  # NOTE: `source` below runs the suite file's top-level statements in THIS function's
  # scope (bash does not give sourced code a fresh scope) — a plain (non-`local`)
  # assignment in the suite file, e.g. cull.test.sh's `before="$(cat lib.sh)"`, would
  # silently clobber a same-named local here. Every bookkeeping var is therefore given
  # a `__hc_rt_` prefix that suite files won't plausibly reuse.
  local __hc_rt_suite="$1" __hc_rt_file
  __hc_rt_file="$ROOT/tests/${__hc_rt_suite}.test.sh"
  [ -f "$__hc_rt_file" ] || fail "no such suite: $__hc_rt_suite ($__hc_rt_file not found)"
  echo "=== suite: $__hc_rt_suite ==="
  local __hc_rt_before __hc_rt_after __hc_rt_new_fns __hc_rt_fn
  __hc_rt_before="$(declare -F | awk '{print $3}' | sort)"
  # shellcheck disable=SC1090
  source "$__hc_rt_file"
  __hc_rt_after="$(declare -F | awk '{print $3}' | sort)"
  __hc_rt_new_fns="$(comm -13 <(printf '%s\n' "$__hc_rt_before") <(printf '%s\n' "$__hc_rt_after") | grep '^test_' || true)"
  [ -z "$__hc_rt_new_fns" ] && return 0
  while IFS= read -r __hc_rt_fn; do
    [ -z "$__hc_rt_fn" ] && continue
    "$__hc_rt_fn"
    ok "$__hc_rt_fn"
    unset -f "$__hc_rt_fn"
  done <<< "$__hc_rt_new_fns"
}

if [ "$#" -ge 1 ]; then
  _run_suite "$1"
  echo "ALL $(echo "$1" | tr '[:lower:]' '[:upper:]') TESTS PASSED"
else
  for f in "$ROOT"/tests/*.test.sh; do
    _run_suite "$(basename "$f" .test.sh)"
  done
  echo "ALL TESTS PASSED"
fi
