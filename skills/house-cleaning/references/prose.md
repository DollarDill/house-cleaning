# Word-level deletion for prose

The oracle for prose is meaning: delete the word or sentence; if a reader loses
nothing, it was dead. No machine verdict exists — non-trivial deletions are proposals.

Delete on sight (trivially safe):
- Filler: "in order to"→"to", "it should be noted that"→∅, "basically", "actually", "very".
- Restating the adjacent code/heading in different words.
- Meta-commentary: "this section describes…" — the section already does.
- Duplicated statements — keep the single source, delete the echo.

Propose (meaning-adjacent):
- Comments explaining WHY — keep unless stale; a stale why is worse than none.
- Warnings, caveats, security notes — never auto-delete; propose with the reason.
- Doc sections describing removed features — propose deletion referencing the removal.

Never touch:
- License headers, attribution, legal text.
- Changelog history entries.
