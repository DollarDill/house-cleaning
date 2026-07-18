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
  # No-content rule: reject forbidden keys anywhere in the fields object, at ANY depth —
  # top-level or nested inside any sub-object (e.g. {"evidence":{"content":"..."}}) — so no
  # secret or file content can enter committed artifacts via a nested field.
  local forb_json found
  # shellcheck disable=SC2086  # intentional word-splitting of the space-separated key list
  forb_json="$(printf '%s\n' $FORBIDDEN_KEYS | jq -R . | jq -sc .)"
  found="$(echo "$fields" | jq -r --argjson forb "$forb_json" \
    '[.. | objects | keys[]?] | unique | map(select(IN($forb[]))) | .[]' 2>/dev/null || true)"
  if [ -n "$found" ]; then
    echo "ledger: refuse — record carries forbidden key '$(echo "$found" | head -1)' (no code/content in committed artifacts, any depth)" >&2
    exit 2
  fi
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

changed_since() {
  local sha="$1"
  git diff --name-only "$sha" HEAD
}

# Does any recorded probe pertain to candidate unit $1 (bash 4+ regex — see plan Global
# Constraints)? Review fix (cc-eval-vmk3): coverage MUST be counted by candidate-unit
# MEMBERSHIP, not scalar record-count subtraction — probe_bisect/_ddmin (batch) split ONE
# candidate into MULTIPLE leaf probe records, so "count of probe records" is not "count of
# swept candidates" and a naive subtraction under-reports uncovered work (can print "0
# uncovered" while a whole candidate was never touched — a false full-coverage claim, exactly
# what "scale honesty" forbids). A file candidate is swept by ANY probe on the same file
# (exact whole-file match, or any sub-range — bisection of a file-shaped unit still covers it).
# A region candidate F:a-b is swept by an exact match, a sub-range fully inside [a,b], or a
# whole-file probe on F (which trivially covers every region of F).
_candidate_is_swept() {
  local c="$1" probes="$2" p cfile pfile ca cb pa pb
  cfile="$(echo "$c" | sed -E 's/:[0-9]+-[0-9]+$//')"
  ca=""; cb=""
  if [[ "$c" =~ :([0-9]+)-([0-9]+)$ ]]; then ca="${BASH_REMATCH[1]}"; cb="${BASH_REMATCH[2]}"; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pfile="$(echo "$p" | sed -E 's/:[0-9]+-[0-9]+$//')"
    [ "$pfile" = "$cfile" ] || continue
    [ -z "$ca" ] && return 0   # file candidate: any same-file probe counts as examined
    pa=""; pb=""
    if [[ "$p" =~ :([0-9]+)-([0-9]+)$ ]]; then pa="${BASH_REMATCH[1]}"; pb="${BASH_REMATCH[2]}"; fi
    [ -z "$pa" ] && return 0   # whole-file probe covers every region of it
    [ "$pa" -ge "$ca" ] && [ "$pb" -le "$cb" ] && return 0   # sub-range fully within [ca,cb]
  done <<< "$probes"
  return 1
}

coverage_summary() {
  local run_id="$1" L; L="$(_run_dir "$run_id")/ledger.jsonl"
  local cand_list; cand_list="$(jq -r 'select(.type=="candidate")|.unit' "$L" 2>/dev/null | sort -u || true)"
  local probe_list; probe_list="$(jq -r 'select(.type=="probe")|.unit' "$L" 2>/dev/null || true)"
  local candidates=0 swept=0 c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    candidates=$((candidates + 1))
    _candidate_is_swept "$c" "$probe_list" && swept=$((swept + 1))
  done <<< "$cand_list"
  local uncovered=$(( candidates - swept )); [ "$uncovered" -lt 0 ] && uncovered=0
  echo "coverage: swept ${swept} of ${candidates} candidates; ${uncovered} uncovered$( [ "$uncovered" -gt 0 ] && echo ' — run again to continue' )"
}

# coverage-view --since (resumption invalidation): identical to coverage_view, but a unit's
# coverage is treated as INVALID (omitted) if its underlying file changed since the unit's
# OWN recorded git_sha — or if the record carries no git_sha at all (can't confirm
# freshness ⇒ fail closed; never trust stale line numbers, per Global Constraints "scale
# honesty"). Consumes the git_sha every probe record now carries (file/region/bisect/batch
# alike). Per-unit (not a single global diff against one caller-supplied sha) because
# coverage_view aggregates across runs and different units can carry different recorded
# shas (last-write-wins).
coverage_view_since() {
  local cov; cov="$(coverage_view)"
  [ "$cov" = "{}" ] && { echo "$cov"; return 0; }
  local result="$cov" u gs file changed
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    gs="$(echo "$cov" | jq -r --arg u "$u" '.[$u].git_sha // ""')"
    if [ -z "$gs" ]; then
      result="$(echo "$result" | jq -c --arg u "$u" 'del(.[$u])')"
      continue
    fi
    # unit is either a bare file path (file/batch granularity) or "path:start-end"
    # (region/line granularity) — strip the trailing range suffix to get the file.
    file="$(echo "$u" | sed -E 's/:[0-9]+-[0-9]+$//')"
    if ! changed="$(git diff --name-only "$gs" HEAD -- "$file" 2>/dev/null)"; then
      # unresolvable/bad recorded sha ⇒ can't confirm freshness ⇒ fail closed too.
      result="$(echo "$result" | jq -c --arg u "$u" 'del(.[$u])')"
      continue
    fi
    if [ -n "$changed" ]; then
      result="$(echo "$result" | jq -c --arg u "$u" 'del(.[$u])')"
    fi
  done < <(echo "$cov" | jq -r 'keys[]')
  echo "$result"
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
  coverage-view) shift; case "${1:-}" in
      "") coverage_view ;;
      --since) coverage_view_since ;;
      *) echo "usage: ledger.sh coverage-view [--since]" >&2; exit 2 ;;
    esac ;;
  regen-audit) shift; regen_audit "$@" ;;
  changed-since) shift; changed_since "$@" ;;
  coverage-summary) shift; coverage_summary "$@" ;;
  *) echo "usage: ledger.sh init|append|coverage-view|regen-audit|changed-since|coverage-summary ..." >&2; exit 2 ;;
esac
