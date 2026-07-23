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

# Stage 4 must require a `kept` record for every DECLINED unit, not just a `decision` record.
# Observed failure this closes: a run declined two out-of-scope units ("package.json (exports
# map)" and a line-level unit inside a live file) and wrote `decision:declined` for each, but
# no `kept` record. Downstream, a proposal set derived from the decision stream treats a
# `kept` record as the only trustworthy retraction signal — agent-authored decision records
# are deliberately non-retracting, so an agent cannot launder a wrongly-surfaced unit by
# declining it. With no `kept` record those two declined units stayed in the derived proposal
# set and scored as over-reach, blocking promotion. A third unit in the same run was declined
# AND kept-recorded, retracted cleanly, and did not trip — which is what pinned the missing
# record as the cause. Stage 1 already states the contract ("every in-scope unit is a
# candidate or kept ledger record"); this pins that Stage 4 restates it at decline time,
# which is where the ruling actually happens.
test_skill_stage4_requires_kept_record_for_declined_units() {
  local S slice; S="$(_skill_md)"
  slice="$(awk '
    $0 ~ "^## Stage 4([^0-9]|$)" { inseg=1; next }
    inseg && /^## / { exit }
    inseg { print }
  ' "$S")"
  printf '%s\n' "$slice" | grep -qi 'kept' \
    || fail "Stage 4 never mentions a 'kept' record — a declined unit needs one or it stays in the derived proposal set"
  # The Done-when is the checkable close of the stage, so the requirement must live there too
  # — not only as narrative prose an agent can skim past.
  printf '%s\n' "$slice" | grep -i 'done when' | grep -qi 'kept' \
    || fail "Stage 4's Done-when does not require a 'kept' record for declined units"
}

# The Iron Law is the section's top-level gate. Pinned as an INVARIANT (the exact rule
# string, and that it sits in a fenced block — the corpus form that makes it read as a law
# rather than as prose), never the surrounding narrative. Anchored on CANDIDACY rather than
# on a probe verdict: word-level prose proposals legitimately carry no probe record at all
# (references/ledger-schema.md), so a probe-anchored law would bar a documented capability.
test_skill_iron_law_present() {
  local S; S="$(_skill_md)"
  grep -qF 'NO PROPOSAL WITHOUT A CANDIDATE RECORD' "$S" \
    || fail "SKILL.md is missing the Iron Law"
  awk '/^```/ { f = !f; next }
       f && /NO PROPOSAL WITHOUT A CANDIDATE RECORD/ { found = 1 }
       END { exit !found }' "$S" \
    || fail "Iron Law present but not inside a fenced code block"
}

# Stage ordering was stated by the stage bodies but never DEFENDED. The eval showed
# cull_run before the first oracle_detect in 3 of 4 gated scenarios. Pinned as an
# invariant because a probe against an undetected oracle yields verdicts that are
# indistinguishable from real ones — a silent-corruption path, not a style issue.
# Deliberately NOT paired with a branch-ordering line: 'house-cleaning/* branch only'
# is a carried floor the scripts enforce, and SKILL.md forbids restating those.
test_skill_forbids_cull_before_stage_0() {
  local S; S="$(_skill_md)"
  # Pattern is deliberately backtick-free: a markdown-backticked pattern trips shellcheck
  # SC2016 and is brittle if the prose is reformatted. "before Stage 0 closes" appears only
  # in this bright line, so it pins the same invariant. Verified shellcheck-clean.
  grep -qi 'before Stage 0 closes' "$S" \
    || fail "SKILL.md missing the Stage-0 ordering bright line"
}

# The rationalization table is the third tier of the boundary section. Pinned by HEADER
# ONLY — never row contents: rows are expected to evolve as new failure modes are
# observed, and asserting them would make the suite a prose-structure test, which the
# authoring canon forbids. The header's presence is the invariant.
test_skill_has_rationalization_table() {
  local S; S="$(_skill_md)"
  grep -qE '^\| *Thought *\| *Reality *\|' "$S" \
    || fail "SKILL.md missing the rationalization table header"
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
  # CI-rubric parity (.github/workflows/ci.yml "rubric mechanical"): strict < 500, counted
  # the way CI counts (grep -c '', which counts a final unterminated line too). Aligning the
  # method AND the strict bound closes the test<->CI gap for the line budget.
  n="$(grep -c '' "$S")"
  [ "$n" -lt 500 ] || fail "SKILL.md not under 500 lines ($n); CI rubric requires strict < 500 (target ~150)"
}

# --- CI "rubric mechanical" parity (all three checks replicated so `run-tests.sh` fails
# locally on anything CI would reject — the gap that let a pronoun'd description ship). ---

test_skill_description_is_third_person() {
  local S desc; S="$(_skill_md)"
  # The human-facing description must read third-person / impersonal: NO first- or
  # second-person pronoun. Regex + extraction are verbatim from the CI rubric step.
  desc="$(sed -n 's/^description:[[:space:]]*//p' "$S" | head -1)"
  if echo "$desc" | grep -qiE '\b(I|we|you|your|yours|our|ours|us|my|me)\b'; then
    fail "description carries a first/second-person pronoun (CI rubric exit 1): $desc"
  fi
}

test_skill_no_internal_path_references() {
  local hits
  # The distributable skill must not leak internal ADR / decisions / .internal references,
  # or internal tracker/bead IDs (e.g. cc-eval-vmk3) left behind in review-fix comments.
  # Mirror CI's `grep -rnE ... skills/ README.md`; fail if ANYTHING matches.
  hits="$(grep -rnE 'ADR-[0-9]|\.internal/|decisions/|cc-eval-' "${ROOT:-.}/skills/" "${ROOT:-.}/README.md" || true)"
  [ -z "$hits" ] || fail "internal ADR/.internal/decisions/tracker-ID reference in distributable skill:
$hits"
}
