#!/usr/bin/env bash
set -euo pipefail
# cull.sh — the deletion test, mechanically: delete → oracle → keep (atomic commit) or restore.
# Single-writer contract: this script appends verdicts ONLY to .house-cleaning/verdicts.log;
# the agent owns CULLING.md and regenerates it from this log.
#   file <path> [tier]
#   region <path> <start> <end> [tier]
#   bisect <path> <start> <end> [tier]      (Task 4)
#   batch <listfile> [tier]                 (Task 4)
#   untracked <listfile>                    (Task 4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=".house-cleaning/verdicts.log"

log() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" "$5" >> "$LOG"; }
oracle() { "$SCRIPT_DIR/oracle.sh" run >/dev/null; }
sha() { git rev-parse --short HEAD; }

guard() {
  # GNU floor — BSD sed -i without a suffix is silently destructive; fail loud instead.
  sed --version 2>/dev/null | grep -q GNU || { echo "cull: refuse — GNU sed required (see README Requirements)" >&2; exit 2; }
  mkdir -p .house-cleaning
  # Scratch-dir hygiene: locally exclude .house-cleaning/ so it can never be swept into a
  # cull commit (worktree-safe — info/exclude lives per-worktree, not in tracked .gitignore).
  local ex; ex="$(git rev-parse --git-path info/exclude)"
  grep -qxF '.house-cleaning/' "$ex" 2>/dev/null || echo '.house-cleaning/' >> "$ex"
  local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
  case "$branch" in
    house-cleaning/*) ;;
    *) echo "cull: refuse — on '$branch', need a house-cleaning/* branch" >&2; exit 2 ;;
  esac
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "cull: refuse — dirty tree" >&2; exit 2
  fi
}

commit() { local msg="$1"; shift; git add -A -- "$@"; git commit -q -m "house-cleaning: $msg"; }

# restore MUST leave the path byte-identical to HEAD; a failed restore halts everything (exit 3).
restore() {
  git checkout -q -- "$1"
  git diff --quiet -- "$1" || { echo "cull: HALT — restore of $1 failed to reproduce HEAD state" >&2; exit 3; }
}

del_region() { sed -i -- "${2},${3}d" "$1"; }

# path_guard — every target must be a repo-relative, existing path that resolves INSIDE the
# repo; closes both the rm -rf escape class and the tracked-symlink-to-outside escape class.
path_guard() {
  case "$1" in
    /*|~*) echo "cull: refuse — absolute path '$1'" >&2; exit 2 ;;
    *..*) echo "cull: refuse — path traversal in '$1'" >&2; exit 2 ;;
  esac
  [ -e "$1" ] || { echo "cull: refuse — '$1' does not exist" >&2; exit 2; }
  local rp root
  rp="$(realpath "$1")"
  root="$(git rev-parse --show-toplevel)"
  case "$rp" in
    "$root"/*) ;;
    *) echo "cull: refuse — '$1' resolves outside the repo ($rp)" >&2; exit 2 ;;
  esac
}

# tracked_guard — only tracked paths go through file/region; untracked targets go through
# the (Task 4) untracked verb instead. Also closes restore()'s untracked-target crash: a
# `git checkout -- <untracked path>` fails under set -e with no verdict logged and the file
# permanently gone.
tracked_guard() {
  git ls-files --error-unmatch "$1" >/dev/null 2>&1 || {
    echo "cull: refuse — '$1' is not tracked (untracked files go through the untracked verb)" >&2
    exit 2
  }
}

# keep-list is untouchable BY CONSTRUCTION: any target matching a .house-cleaning/keep glob refuses.
keep_guard() {
  [ -f .house-cleaning/keep ] || return 0
  local pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in \#*) continue ;; esac
    # shellcheck disable=SC2254
    case "$1" in $pat) echo "cull: refuse — $1 matches keep-list pattern '$pat'" >&2; exit 2 ;; esac
  done < .house-cleaning/keep
}

file_cmd() {
  local path="$1" tier="${2:-HIGH}"
  guard
  path_guard "$path"; keep_guard "$path"; tracked_guard "$path"
  rm -- "$path"
  if oracle; then
    commit "$path [file] [$tier]" "$path"
    log file "$path" - deleted "$(sha)"
  else
    restore "$path"
    log file "$path" - kept-live -
    return 1
  fi
}

region_cmd() {
  local path="$1" start="$2" end="$3" tier="${4:-HIGH}"
  guard
  path_guard "$path"; keep_guard "$path"; tracked_guard "$path"
  del_region "$path" "$start" "$end"
  if oracle; then
    commit "$path:$start-$end [-$((end - start + 1)) lines] [$tier]" "$path"
    log region "$path" "$start-$end" deleted "$(sha)"
  else
    restore "$path"
    log region "$path" "$start-$end" kept-live -
    return 1
  fi
}

case "${1:-}" in
  file) shift; file_cmd "$@" ;;
  region) shift; region_cmd "$@" ;;
  *) echo "usage: cull.sh file|region|bisect|batch|untracked ..." >&2; exit 2 ;;
esac
