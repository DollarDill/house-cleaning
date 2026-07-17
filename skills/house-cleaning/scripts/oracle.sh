#!/usr/bin/env bash
set -euo pipefail
# oracle.sh — detect and run the target project's verification oracle.
#   detect : print proposed oracle commands (one per line). NEVER executes them —
#            the user must confirm the list before it is written to .house-cleaning/oracle.
#   run    : execute .house-cleaning/oracle lines in order.
#            exit 0 green | 1 red | 2 oracle file missing.
#            On a red command: retry it once — a flip to green is a FLAKE
#            (logged, treated as green here; the skill demotes tiers on flakes).
ORACLE_FILE=".house-cleaning/oracle"
LOG=".house-cleaning/verdicts.log"
TIMEOUT_SECS="${ORACLE_TIMEOUT:-600}"

run_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECS" bash -c "$1" >/dev/null 2>&1
  else
    bash -c "$1" >/dev/null 2>&1
  fi
}

detect() {
  if [ -f package.json ] && command -v jq >/dev/null 2>&1; then
    jq -r '.scripts // {} | to_entries[]
           | select(.key == "build" or .key == "typecheck" or .key == "test")
           | "npm run \(.key)"' package.json
  fi
  [ -f tsconfig.json ] && echo "npx tsc --noEmit"
  { [ -f pyproject.toml ] || [ -f setup.py ]; } && echo "pytest -q"
  [ -f go.mod ] && { echo "go build ./..."; echo "go test ./..."; }
  [ -f Cargo.toml ] && { echo "cargo build"; echo "cargo test"; }
  [ -f Makefile ] && grep -qE '^test:' Makefile && echo "make test"
  return 0
}

run() {
  [ -f "$ORACLE_FILE" ] || { echo "oracle: missing $ORACLE_FILE — run detect, confirm, write it" >&2; exit 2; }
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    case "$cmd" in \#*) continue ;; esac
    if ! run_cmd "$cmd"; then
      if run_cmd "$cmd"; then
        printf '%s\tflake\t%s\t-\tflake\t-\n' "$(date -u +%FT%TZ)" "$cmd" >> "$LOG"
        echo "oracle: FLAKE (red→green on retry): $cmd" >&2
        continue
      fi
      echo "oracle: RED: $cmd" >&2
      exit 1
    fi
  done < "$ORACLE_FILE"
  echo "oracle: GREEN"
}

case "${1:-}" in
  detect) detect ;;
  run) run ;;
  *) echo "usage: oracle.sh detect|run" >&2; exit 2 ;;
esac
