# shellcheck shell=bash
# skill-contract.test.sh — grep-pinned invariants for the v2 SKILL.md (plan Task 6 Step 1).
# The SKILL.md is prose, not a script; these assertions are the machine-checkable contract
# that the Pocock-lean rewrite must keep true — the frontmatter mode, the safety bright
# lines (verbatim), Stages 0–5 each closing on a checkable Done-when, the steering
# leading-words, the one-level reference pointers, and the line budget.
#
# Sourced by run-tests.sh (function-style suite): each test_* function is discovered and
# called. $ROOT / fail() come from run-tests.sh; the relative fallback lets the suite also
# be sourced standalone from the repo root.

_skill_md() { echo "${ROOT:-.}/skills/house-cleaning/SKILL.md"; }

test_skill_frontmatter_is_user_invoked() {
  local S; S="$(_skill_md)"
  grep -q '^disable-model-invocation: true' "$S" || fail "SKILL.md must stay user-invoked (disable-model-invocation: true)"
  grep -q '^description:' "$S" || fail "SKILL.md frontmatter missing a description line"
  grep -q '^name:' "$S" || fail "SKILL.md frontmatter missing a name line"
}

test_skill_bright_lines_verbatim() {
  local S phrase; S="$(_skill_md)"
  # Case-insensitive, verbatim safety bright lines (spec §6). "coverage:" is the mandatory
  # forced-visible coverage-summary line (spec §3 Stage 3 / ledger.sh coverage-summary).
  for phrase in "never auto-delete" "always revert" "forced human" "never merge red" "coverage:"; do
    grep -qi "$phrase" "$S" || fail "missing bright line: $phrase"
  done
}

test_skill_stages_0_to_5_present() {
  local S n; S="$(_skill_md)"
  for n in 0 1 2 3 4 5; do
    grep -qE "^## Stage $n\b" "$S" || fail "missing Stage $n heading"
  done
}

test_skill_every_stage_has_done_when() {
  local S n slice; S="$(_skill_md)"
  # Per-stage STRUCTURAL check (not a global count): each Stage N's OWN section must close
  # on a checkable Done-when. Slice from the Stage N heading to the next level-2 heading, so
  # a Done-when clustered elsewhere can't satisfy a stage vacuously. awk avoids sed \b
  # portability worries; the "([^0-9]|$)" guard keeps "Stage 1" from matching "Stage 10".
  for n in 0 1 2 3 4 5; do
    slice="$(awk -v n="$n" '
      $0 ~ "^## Stage " n "([^0-9]|$)" { inseg=1; next }
      inseg && /^## / { exit }
      inseg { print }
    ' "$S")"
    printf '%s\n' "$slice" | grep -qi 'done when' || fail "Stage $n has no 'Done when' in its own section"
  done
}

test_skill_leading_words_present() {
  local S word; S="$(_skill_md)"
  # Steering vocabulary (spec §2/§3) — used consistently, greppable here.
  for word in "deletion test" "oracle" "probe" "propose" "coverage ledger" "coarse-to-fine" "batch-first" "audit"; do
    grep -qi "$word" "$S" || fail "missing leading word: $word"
  done
}

test_skill_reference_pointers_are_one_level() {
  local S ref; S="$(_skill_md)"
  # Branch-only reference behind one-level pointers (references/<file>.md).
  for ref in "references/prose.md" "references/tools.md" "references/ledger-schema.md"; do
    grep -q "$ref" "$S" || fail "missing one-level reference pointer: $ref"
  done
}

test_skill_body_within_line_budget() {
  local S n; S="$(_skill_md)"
  n="$(wc -l < "$S")"
  [ "$n" -le 500 ] || fail "SKILL.md over 500 lines ($n) — hard budget is 500 (target ~150)"
}
