#!/usr/bin/env bash
set -euo pipefail
# ledger.sh — canonical per-run audit/coverage ledger. Records IDENTIFIERS + evidence-type
# + verdict ONLY; never file contents (security floor). JSONL, one record per line.
command -v jq >/dev/null 2>&1 || { echo "ledger: refuse — jq required (see README Requirements)" >&2; exit 2; }
HC_DIR=".house-cleaning"
FORBIDDEN_KEYS='content diff code body snippet'

_run_dir() { echo "$HC_DIR/runs/$1"; }

init() {
  local run_id="$1" scope="$2" git_sha="$3" dir; dir="$(_run_dir "$run_id")"
  mkdir -p "$dir"
  jq -nc --arg r "$run_id" --arg s "$scope" --arg g "$git_sha" --arg t "$(date -u +%FT%TZ)" \
     '{type:"run",run_id:$r,scope:$s,git_sha:$g,ts:$t}' >> "$dir/ledger.jsonl"
}

append() {
  local run_id="$1" type="$2" fields="$3" dir; dir="$(_run_dir "$run_id")"
  [ -d "$dir" ] || { echo "ledger: refuse — run '$run_id' not initialized" >&2; exit 2; }
  # No-content rule: reject forbidden keys anywhere in the fields object.
  local k
  for k in $FORBIDDEN_KEYS; do
    if echo "$fields" | jq -e --arg k "$k" 'has($k)' >/dev/null 2>&1; then
      echo "ledger: refuse — record carries forbidden key '$k' (no code/content in committed artifacts)" >&2; exit 2
    fi
  done
  # Newline guard + merge type + ts; jq -c guarantees single-line output.
  echo "$fields" | jq -c --arg ty "$type" --arg t "$(date -u +%FT%TZ)" '. + {type:$ty, ts:$t}' \
    >> "$dir/ledger.jsonl"
}

coverage_view() {
  # Aggregate all runs' probe/coverage records; last record per unit wins (files sorted → run order).
  local files; files=$(ls -1 "$HC_DIR"/runs/*/ledger.jsonl 2>/dev/null || true)
  [ -n "$files" ] || { echo '{}'; return 0; }
  # shellcheck disable=SC2086
  cat $files | jq -s 'map(select(.type=="probe" or .type=="coverage"))
    | reduce .[] as $r ({}; .[$r.unit // $r.scope] = {granularity:$r.granularity, verdict:$r.verdict, git_sha:$r.git_sha})'
}

regen_audit() {
  local run_id="$1" dir; dir="$(_run_dir "$run_id")"
  local L="$dir/ledger.jsonl" A="$dir/audit.md"
  { echo "# House-cleaning audit — run $run_id"; echo
    echo "## Scope & oracle"; jq -r 'select(.type=="run")|"- scope: \(.scope) @ \(.git_sha) (\(.ts))"' "$L"
    jq -r 'select(.type=="oracle")|"- oracle: \(.commands|join(" ; "))"' "$L"
    jq -r 'select(.type=="baseline")|"- baseline: \(.result)\(if .flake then " (flake)" else "" end)"' "$L"
    echo; echo "## Candidates & verdicts"
    jq -r 'select(.type=="probe")|"- [\(.verdict)] \(.unit) (\(.granularity), oracle=\(.oracle // "-"))"' "$L"
    echo; echo "## Proposals"
    jq -r 'select(.type=="proposal")|"- [\(.confidence)] \(.unit)\(if .security_capped then " [security-capped]" else "" end) — \(.recommendation)"' "$L"
    echo; echo "## Decisions & applied"
    jq -r 'select(.type=="decision")|"- \(.decision): \(.unit)"' "$L"
    jq -r 'select(.type=="applied")|"- applied \(.unit) @ \(.sha)"' "$L"
    echo; echo "## Coverage"
    jq -r 'select(.type=="coverage")|"- \(.scope) [\(.granularity)]: \(.status) @ \(.git_sha)"' "$L"
  } > "$A"
}

case "${1:-}" in
  init) shift; init "$@" ;;
  append) shift; append "$@" ;;
  coverage-view) coverage_view ;;
  regen-audit) shift; regen_audit "$@" ;;
  *) echo "usage: ledger.sh init|append|coverage-view|regen-audit ..." >&2; exit 2 ;;
esac
