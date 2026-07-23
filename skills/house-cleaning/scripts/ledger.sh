#!/usr/bin/env bash
set -euo pipefail
# ledger.sh — canonical per-run audit/coverage ledger. Records IDENTIFIERS + evidence-type
# + verdict ONLY; never file contents (security floor). JSONL, one record per line.
command -v jq >/dev/null 2>&1 || { echo "ledger: refuse — jq required (see README Requirements)" >&2; exit 2; }
HC_DIR=".house-cleaning"
FORBIDDEN_KEYS='content diff code body snippet'
# Storage two-way-door (plan Global Constraints): `committed` (default) durably commits
# the ledger — checkpoint on the current branch, persist-base additively onto the base
# branch. `local` is the escape hatch — no commits anywhere, .house-cleaning/ gitignored
# per-repo via .git/info/exclude.
HC_LEDGER_MODE="${HC_LEDGER_MODE:-committed}"

_run_dir() { echo "$HC_DIR/runs/$1"; }
_local_mode() { [ "$HC_LEDGER_MODE" = "local" ]; }
_ensure_local_ignore() {
  local ex; ex="$(git rev-parse --git-path info/exclude)"
  grep -qxF "$HC_DIR/" "$ex" 2>/dev/null || echo "$HC_DIR/" >> "$ex"
}

# Run-id stickiness: the "active run" pointer, so callers in a fresh shell (HC_RUN_ID
# unset — the common case across separate tool invocations) can still resolve which run
# is active without re-exporting HC_RUN_ID every time.
_current_run_file() { echo "$HC_DIR/current-run"; }

# Strict ALLOWLIST (not a denylist — traversal/absolute/leading-dash/leading-underscore/
# control-char shapes are rejected by construction, not enumerated):
# ^[A-Za-z0-9][A-Za-z0-9_-]*$, length <= 64 — first char must be alphanumeric (underscore
# is allowed mid-string but not as the leading char). Run ids flow into _run_dir() as a
# raw path segment, so anything but a tight allowlist is a path-traversal / arg-injection
# vector (untrusted-repo input).
_valid_run_id() {
  case "$1" in
    *[!A-Za-z0-9_-]*|-*|_*|'') return 1 ;;
    *) [ "${#1}" -le 64 ] ;;
  esac
}

# resolve-run-id: HC_RUN_ID if set, else the contents of .house-cleaning/current-run.
# Refuses (non-zero exit, message to stderr) on an unsafe/empty shape — fail-closed.
_resolve_run_id() {
  local rid="${HC_RUN_ID:-}"
  [ -n "$rid" ] || { [ -f "$(_current_run_file)" ] && rid="$(cat "$(_current_run_file)")"; }
  _valid_run_id "$rid" || { echo "ledger: refuse — unsafe/empty run id" >&2; return 2; }
  printf '%s' "$rid"
}

init() {
  local run_id="$1" scope="$2" git_sha="$3" dir; dir="$(_run_dir "$run_id")"
  _valid_run_id "$run_id" || { echo "ledger: refuse — unsafe/empty run id '$run_id'" >&2; exit 2; }
  mkdir -p "$dir"
  jq -nc --arg r "$run_id" --arg s "$scope" --arg g "$git_sha" --arg t "$(date -u +%FT%TZ)" \
     '{type:"run",run_id:$r,scope:$s,git_sha:$g,ts:$t}' >> "$dir/ledger.jsonl"
  mkdir -p "$HC_DIR"
  printf '%s' "$run_id" > "$(_current_run_file)"
}

append() {
  local run_id="${1:-}" type="${2:-}" fields="${3:-}" dir
  if [ -z "$run_id" ]; then
    # No explicit run id given: resolve via Task-1 stickiness (HC_RUN_ID, else
    # .house-cleaning/current-run) so a fresh shell with HC_RUN_ID unset but a prior
    # `init` still appends to the right run.
    run_id="$(_resolve_run_id 2>/dev/null)" || run_id=""
  fi
  [ -n "$run_id" ] || run_id="$(date -u +%Y-%m-%d-%H%M%S)"   # nothing resolvable: default fresh id
  # Validate UNCONDITIONALLY here, before _run_dir/-d — never only inside the lazy-init
  # branch below. If the id's target dir HAPPENS TO ALREADY EXIST (e.g. a repo that
  # legitimately has an `etc/` dir two levels above runs/, or '.' which resolves to
  # runs/ itself once any run exists), skipping validation there would let an unsafe id
  # write a record outside `.house-cleaning/runs/` with no sanitization at all — the
  # `-d` test must never gate whether sanitization happens.
  _valid_run_id "$run_id" || { echo "ledger: refuse — unsafe run id" >&2; exit 2; }
  dir="$(_run_dir "$run_id")"
  if [ ! -d "$dir" ]; then
    # Lazy-init, fresh-only: fires ONLY when NO run dir exists at all for the resolved
    # id. This must NEVER reuse/redirect a resolved-but-uninitialized pointer into a
    # different, stale run dir — the check above is against THIS id's own dir, so a
    # stale run under another id is never touched.
    mkdir -p "$dir"
    jq -nc --arg r "$run_id" --arg t "$(date -u +%FT%TZ)" \
       '{type:"run",run_id:$r,ts:$t,lazy:true}' >> "$dir/ledger.jsonl"
  fi
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
  # Decision-record shape floor: a `type:decision` record exists to convey exactly one thing —
  # the ruling — so reject at append time when it is absent or not one of the two schema values
  # (references/ledger-schema.md §decision). Same fail-closed posture as the content floor
  # above. Without this a shape-invalid record is accepted silently, and the damage surfaces
  # far from its cause: `cull.sh`'s `_is_approved` reads `.[-1].decision` and so fails closed
  # (no wrongful deletion), but any downstream auditor reading the ledger cannot distinguish
  # "declined" from "unreadable" — an unreadable ruling is indeterminate, not a decision, and
  # a consumer that must treat indeterminate as not-a-pass has no way to recover the intent
  # after the fact. Refusing here surfaces the authoring mistake in seconds instead. The bare
  # equality comparison covers every invalid shape at once: absent, null, "", and wrong-type
  # (array/number/object) all compare false.
  if [ "$type" = "decision" ]; then
    echo "$fields" | jq -e '.decision == "approved" or .decision == "declined"' >/dev/null 2>&1 \
      || { echo "ledger: refuse — type:decision record must carry decision:\"approved\"|\"declined\"" >&2; exit 2; }
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
# Constraints)? Review fix: coverage MUST be counted by candidate-unit
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

# checkpoint <run_id> — commit .house-cleaning/runs/<run_id>/ on the CURRENT (house-
# cleaning) branch as a dedicated commit. No-op (beyond gitignoring) in local mode.
# Idempotent: a second call with nothing new staged is a silent no-op, not an error.
checkpoint() {
  local run_id="$1"
  if _local_mode; then _ensure_local_ignore; return 0; fi
  local run_dir; run_dir="$(_run_dir "$run_id")"
  [ -d "$run_dir" ] || { echo "ledger: refuse — checkpoint: run '$run_id' not initialized" >&2; exit 2; }
  # -f: this add is pathspec-scoped to the tool's own additive $run_dir, so force-adding is
  # safe — it never touches user code — and necessary: committed mode (the default) must
  # still work when .house-cleaning/ is git-ignored (a v1-upgrader's cull.sh left it in
  # .git/info/exclude in every repo it cleaned; this file's own local mode does the same via
  # _ensure_local_ignore). A plain `git add` on an explicitly-ignored path errors out rather
  # than silently skipping it, which would otherwise break the committed-mode default.
  git add -f -- "$run_dir" || { echo "ledger: refuse — checkpoint: could not stage '$run_dir'" >&2; exit 2; }
  # Dedicated, additive-only commit: pathspec-restrict `commit` to $run_dir so any
  # unrelated staged content elsewhere in the tree is never swept into this commit.
  git diff --cached --quiet -- "$run_dir" && return 0   # nothing new to checkpoint
  git commit -q -m "house-cleaning: ledger checkpoint ($run_id)" -- "$run_dir" \
    || { echo "ledger: refuse — checkpoint: commit failed for run '$run_id'" >&2; exit 2; }
}

# Try to return HEAD to $1 (the original branch). On success, return 0 — the caller
# decides what exit status to report for the operation that preceded the return. On
# failure, HALT loudly (exit 3) rather than silently leaving the user on $2 — per plan
# Task 5 robustness requirement, the one failure mode this function must never produce
# is a swallowed stranding.
_return_or_halt() {
  local target="$1" stranded_on="$2" context="$3"
  git checkout -q "$target" 2>/dev/null && return 0
  echo "ledger: HALT — persist-base: $context; FAILED to return to '$target' — you are stranded on '$stranded_on'. Run: git checkout $target" >&2
  exit 3
}

# persist-base <base_branch> <run_id> — additively persist .house-cleaning/runs/<run_id>/
# onto <base_branch>, then return to the current (house-cleaning) branch. No-op (beyond
# gitignoring) in local mode.
#
# Critical mechanics (see plan Task 5 + task brief "critical coordination point"): the
# run's ledger files are tracked and committed on the CURRENT branch only (via
# checkpoint), never on <base_branch>. Empirically verified two consequences of that:
#   1. A plain `git checkout <base>` DELETES those files from the working tree, because
#      they are tracked-only-on-the-source-branch and <base>'s tree lacks the path — a
#      naive `checkout <base>; add; commit` therefore commits NOTHING.
#   2. Pulling them back via `git checkout <cur> -- <path>` (a treeish pathspec checkout)
#      only works if they are already committed on <cur> — it fails outright against an
#      uncommitted/untracked path. So this function ALWAYS checkpoints <cur> first
#      (idempotent — a no-op if already checkpointed) to guarantee a commit exists to
#      pull from, regardless of whether the caller remembered to checkpoint separately.
persist_base() {
  local base="$1" run_id="$2"
  if _local_mode; then _ensure_local_ignore; return 0; fi
  local run_dir; run_dir="$(_run_dir "$run_id")"
  [ -d "$run_dir" ] || { echo "ledger: refuse — persist-base: run '$run_id' not initialized" >&2; exit 2; }

  local cur; cur="$(git rev-parse --abbrev-ref HEAD)"
  [ "$cur" != "HEAD" ] || { echo "ledger: refuse — persist-base: detached HEAD, need a named current branch" >&2; exit 2; }
  [ "$cur" != "$base" ] || { echo "ledger: refuse — persist-base: current branch is already base '$base'" >&2; exit 2; }

  checkpoint "$run_id"   # guarantee a commit on $cur to pull from (see comment above)

  git checkout -q "$base" || { echo "ledger: refuse — persist-base: could not checkout base '$base' (still on '$cur')" >&2; exit 2; }

  if ! git checkout -q "$cur" -- "$run_dir" 2>/dev/null; then
    echo "ledger: refuse — persist-base: could not pull '$run_dir' from '$cur' onto '$base'" >&2
    _return_or_halt "$cur" "$base" "pull of '$run_dir' from '$cur' failed"
    exit 2
  fi

  # -f: see checkpoint's comment above — same tool-owned-pathspec-only rationale, and the
  # same committed-mode-must-survive-a-gitignored-.house-cleaning/ requirement applies here.
  if ! git add -f -- "$run_dir"; then
    echo "ledger: refuse — persist-base: could not stage '$run_dir' on '$base'" >&2
    _return_or_halt "$cur" "$base" "staging '$run_dir' on '$base' failed"
    exit 2
  fi
  if ! git diff --cached --quiet -- "$run_dir"; then
    # Additive-only, dedicated commit (pathspec-restricted, matches checkpoint's pattern).
    if ! git commit -q -m "house-cleaning: audit history ($run_id)" -- "$run_dir"; then
      git reset -q -- "$run_dir" 2>/dev/null || true
      git checkout -q -- "$run_dir" 2>/dev/null || true
      git clean -fdq -- "$run_dir" 2>/dev/null || true
      echo "ledger: refuse — persist-base: commit onto '$base' failed" >&2
      _return_or_halt "$cur" "$base" "commit onto '$base' failed"
      exit 2
    fi
  fi   # else: already persisted (idempotent no-op) — nothing new to commit

  _return_or_halt "$cur" "$base" "persist-base completed on '$base'"
}

case "${1:-}" in
  init) shift; init "$@" ;;
  resolve-run-id) _resolve_run_id ;;
  append) shift; append "$@" ;;
  coverage-view) shift; case "${1:-}" in
      "") coverage_view ;;
      --since) coverage_view_since ;;
      *) echo "usage: ledger.sh coverage-view [--since]" >&2; exit 2 ;;
    esac ;;
  regen-audit) shift; regen_audit "$@" ;;
  changed-since) shift; changed_since "$@" ;;
  coverage-summary) shift; coverage_summary "$@" ;;
  checkpoint) shift; checkpoint "$@" ;;
  persist-base) shift; persist_base "$@" ;;
  *) echo "usage: ledger.sh init|resolve-run-id|append|coverage-view|regen-audit|changed-since|coverage-summary|checkpoint|persist-base ..." >&2; exit 2 ;;
esac
