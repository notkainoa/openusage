# Merge readiness remediation

Date: 2026-02-09

## Goal
- Make current branch merge-ready by removing known regressions and finishing incomplete test coverage.

## Scope
- Restore accidental frontend analytics removals.
- Keep Z.AI batch-correlated key-validation fix.
- Add missing App tests for Z.AI key-check timeout and start-failure branches.
- Restore accidentally deleted local spec files in working tree.
- Restore release version metadata to `0.5.1`.

## Non-goals
- No provider feature redesign beyond current branch intent.
- No new runtime behavior beyond fixing identified regressions.

## Default decisions
- Assume analytics removal was accidental; restore prior tracking calls.
- Assume release version downgrade to `0.5.0` was accidental; restore `0.5.1`.
- Assume local deleted specs were accidental workspace drift; restore files.

## Validation
1. Targeted vitest runs for updated App/probe/settings/plugin tests.
2. Full `npm test -- --run`.
3. `npm run build`.
4. Clean `git status` (or only intentional modified files remaining).
