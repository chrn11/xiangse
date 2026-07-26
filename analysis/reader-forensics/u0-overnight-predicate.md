# U0 overnight exit predicate (poteto autonomous-run)

## Predicate `U0_GATE_CLEAR`

True only when all hold:

1. F1 F2 F4 F7 R P are PASS (evidence on disk under `analysis/reader-forensics/`).
2. F3 strategy closed. F5 at least PASS_ENTRY. F6 shell OK with content attributed to source not Hook.
3. N01 N02 N04 N05 N08 PASS.
4. N03 at least PASS_ENTRY.
5. N06 is PASS **or** BLOCKED with root cause + human-only next step (no silent PENDING).
6. N07 is PASS including disposable book add+delete **or** BLOCKED with reason.
7. N09 is PASS **or** BLOCKED with reason.
8. N10 may stay PENDING (plan exception TTS).
9. N11 may stay PENDING if no cloud account fixture.
10. Progress board header still says U0 not closed until 1-9 hold. Never claim 全部完成 without this predicate true.
11. U1 remains forbidden until this predicate is true.

## Wake

Fixed-interval iterations. No CI watcher required for device MCP work.
Decision trail: `.audit/u0-overnight.tsv` (gitignored).
