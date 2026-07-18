#!/usr/bin/env bash
set -euo pipefail
# cull.sh — deletion test, mechanically. v2: PROBE (delete→oracle→ALWAYS revert→log) and
# APPLY (authorized manifest→oracle→atomic commit). Probe NEVER commits or mutates.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HC_DIR=".house-cleaning"
oracle() { "$SCRIPT_DIR/oracle.sh" run >/dev/null; }
led() { HC_LEDGER_MODE="${HC_LEDGER_MODE:-committed}" bash "$SCRIPT_DIR/ledger.sh" append "${HC_RUN_ID:?HC_RUN_ID unset}" "$@"; }
sha() { git rev-parse HEAD; }

guard() {
  command -v jq >/dev/null 2>&1 || { echo "cull: refuse — jq required" >&2; exit 2; }
  sed --version 2>/dev/null | grep -q GNU || { echo "cull: refuse — GNU sed required" >&2; exit 2; }
  mkdir -p "$HC_DIR"
  local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
  case "$branch" in house-cleaning/*) ;; *) echo "cull: refuse — on '$branch', need a house-cleaning/* branch" >&2; exit 2 ;; esac
  # Clean-tree EXCLUDING the ledger dir (stress-test B2): every other path still trips this.
  if ! git diff --quiet -- ':(exclude).house-cleaning/' || ! git diff --cached --quiet -- ':(exclude).house-cleaning/'; then
    echo "cull: refuse — dirty tree (outside .house-cleaning/)" >&2; exit 2
  fi
}

# restore MUST leave the path byte-identical to HEAD; a failed restore halts (exit 3).
restore() { git checkout -q -- "$1"; git diff --quiet -- "$1" || { echo "cull: HALT — restore of $1 failed" >&2; exit 3; }; }
del_region() { sed -i -- "${2},${3}d" "$1" || { echo "cull: HALT — sed failed on $1" >&2; exit 4; }; }

path_guard() {
  case "$1" in /*|~*) echo "cull: refuse — absolute path '$1'" >&2; exit 2 ;; *..*) echo "cull: refuse — traversal in '$1'" >&2; exit 2 ;; esac
  [ -e "$1" ] || { echo "cull: refuse — '$1' does not exist" >&2; exit 2; }
  local rp root; rp="$(realpath "$1")"; root="$(git rev-parse --show-toplevel)"
  case "$rp" in "$root"/*) ;; *) echo "cull: refuse — '$1' resolves outside repo ($rp)" >&2; exit 2 ;; esac
  # Defensive (stress-test B2): never target the ledger dir itself.
  case "$rp" in "$root/$HC_DIR"/*|"$root/$HC_DIR") echo "cull: refuse — '$1' is inside $HC_DIR/" >&2; exit 2 ;; esac
}
tracked_guard() { git ls-files --error-unmatch "$1" >/dev/null 2>&1 || { echo "cull: refuse — '$1' not tracked" >&2; exit 2; }; }
keep_guard() { [ -f "$HC_DIR/keep" ] || return 0; local p; while IFS= read -r p; do [ -n "$p" ] || continue; case "$p" in \#*) continue ;; esac
  # shellcheck disable=SC2254
  case "$1" in $p) echo "cull: refuse — $1 matches keep-list '$p'" >&2; exit 2 ;; esac; done < "$HC_DIR/keep"; }
secrets_guard() { case "$1" in *.pem|*.key|*.env|.env.*|*secret*|*credential*|*token*|*.p12|*.keystore)
  echo "cull: refuse — '$1' is secret-shaped; handle via reviewed proposals" >&2; exit 2 ;; esac; }
all_guards() { path_guard "$1"; keep_guard "$1"; secrets_guard "$1"; tracked_guard "$1"; }

# --- PROBE: delete → oracle → ALWAYS revert → log verdict. NEVER commits. ---
probe_file() {
  local path="$1" tier="${2:-HIGH}"; guard; all_guards "$path"
  local gs; gs="$(sha)"; rm -- "$path"
  if oracle; then restore "$path"; led probe "$(jq -nc --arg u "$path" --arg g "$gs" --arg t "$tier" '{unit:$u,granularity:"file",verdict:"provably-dead",oracle:"green",tier:$t,git_sha:$g}')"
  else restore "$path"; led probe "$(jq -nc --arg u "$path" --arg g "$gs" '{unit:$u,granularity:"file",verdict:"kept-live",oracle:"red",git_sha:$g}')"; return 1; fi
}
probe_region() {
  local path="$1" start="$2" end="$3" tier="${4:-HIGH}"; guard; all_guards "$path"
  local gs; gs="$(sha)"; del_region "$path" "$start" "$end"
  if oracle; then restore "$path"; led probe "$(jq -nc --arg u "$path:$start-$end" --arg g "$gs" --arg t "$tier" '{unit:$u,granularity:"region",verdict:"provably-dead",oracle:"green",tier:$t,git_sha:$g}')"
  else restore "$path"; led probe "$(jq -nc --arg u "$path:$start-$end" --arg g "$gs" '{unit:$u,granularity:"region",verdict:"kept-live",oracle:"red",git_sha:$g}')"; return 1; fi
}
probe_bisect() {
  local path="$1" start="$2" end="$3" tier="${4:-HIGH}"; guard; all_guards "$path"
  local gs; gs="$(sha)"; del_region "$path" "$start" "$end"
  if oracle; then restore "$path"; led probe "$(jq -nc --arg u "$path:$start-$end" '{unit:$u,granularity:"region",verdict:"provably-dead",oracle:"green"}')"; return 0; fi
  restore "$path"
  if [ "$start" -ge "$end" ]; then led probe "$(jq -nc --arg u "$path:$start-$end" '{unit:$u,granularity:"line",verdict:"kept-live",oracle:"red"}')"; return 1; fi
  local mid=$(( (start + end) / 2 ))
  probe_bisect "$path" "$((mid + 1))" "$end" "$tier" || true
  probe_bisect "$path" "$start" "$mid" "$tier" || true
}
# batch ddmin: delete set → oracle → ALWAYS revert. green ⇒ all provably-dead; red ⇒ recurse.
# NOTE (T2 fix): forward oracle's own exit code as _try_set's return value (0=green=bash-true,
# nonzero=red=bash-false) so `if _try_set; then <provably-dead>` triggers on green as intended.
# The `oracle || rc=$?` form (rather than a bare `oracle`) keeps this safe under `set -e`.
_try_set() { local p rc=0; for p in "$@"; do rm -- "$p"; done; oracle || rc=$?; for p in "$@"; do restore "$p"; done; return "$rc"; }
_ddmin() { [ "$#" -eq 0 ] && return 0
  if _try_set "$@"; then local p; for p in "$@"; do led probe "$(jq -nc --arg u "$p" '{unit:$u,granularity:"file",verdict:"provably-dead",oracle:"green"}')"; done; return 0; fi
  if [ "$#" -eq 1 ]; then led probe "$(jq -nc --arg u "$1" '{unit:$u,granularity:"file",verdict:"kept-live",oracle:"red"}')"; return 0; fi
  local half=$(( $# / 2 )); local -a first=( "${@:1:half}" ) second=( "${@:half+1}" )
  _ddmin "${second[@]}"; _ddmin "${first[@]}"; }
probe_batch() { local list="$1"; guard; local -a paths=(); local p
  while IFS= read -r p; do [ -n "$p" ] || continue; all_guards "$p"; paths+=( "$p" ); done < "$list"
  [ "${#paths[@]}" -gt 0 ] || { echo "cull: empty batch list" >&2; exit 2; }; _ddmin "${paths[@]}"; }

# apply_cmd (Task 3): authorized manifest → oracle → atomic commit. Stubbed here so
# `cull.sh apply` fails cleanly rather than being an unbound function; T3 replaces this body.
apply_cmd() { echo "cull: apply not yet implemented (Task 3)" >&2; exit 2; }

case "${1:-}" in
  probe) shift; case "${1:-}" in
      file) shift; probe_file "$@" ;; region) shift; probe_region "$@" ;;
      bisect) shift; probe_bisect "$@" ;; batch) shift; probe_batch "$@" ;;
      *) echo "usage: cull.sh probe file|region|bisect|batch ..." >&2; exit 2 ;; esac ;;
  apply) shift; apply_cmd "$@" ;;   # Task 3
  *) echo "usage: cull.sh probe|apply ..." >&2; exit 2 ;;
esac
