# Z.AI no-usage guidance message

Date: 2026-02-07

## Goal
- Replace ambiguous `No usage data available.` with actionable guidance for common real-world cause: no active z.ai subscription/limits.

## Trigger
- Z.AI response is successful but does not produce `TOKENS_LIMIT` / `TIME_LIMIT` lines.

## UX
- Error should state likely cause and concrete next steps:
  1. Check active z.ai subscription/plan limits.
  2. Verify API key belongs to same subscribed account.
  3. If using Claude Code + z.ai, confirm `ANTHROPIC_BASE_URL` points to `api.z.ai` or `open.bigmodel.cn`.

## Validation
- Add plugin regression test for success-without-limits response; assert message includes subscription guidance.
