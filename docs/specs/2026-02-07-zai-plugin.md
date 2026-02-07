# Z.AI plugin

Date: 2026-02-07

## Goal
- Add first-party `zai` provider plugin to OpenUsage.
- Keep implementation aligned with existing plugin runtime (`plugins/<id>/plugin.js` + `plugin.json` + tests).
- Support both Global (`api.z.ai`) and China mainland (`open.bigmodel.cn`) endpoints.

## Research summary
- Open issue exists: `robinebers/openusage#73` ("Add Z.AI plugin", opened 2026-02-05).
- CodexBar (commit `1466284` on 2026-02-02) ships z.ai with:
  - `GET /api/monitor/usage/quota/limit`
  - token env: `Z_AI_API_KEY`
  - endpoint env overrides: `Z_AI_API_HOST`, `Z_AI_QUOTA_URL`
  - region switch: `api.z.ai` vs `open.bigmodel.cn`
- Official z.ai plugin repo (`zai-org/zai-coding-plugins`, commit `64cebff` on 2025-12-25) uses:
  - `GET /api/monitor/usage/model-usage`
  - `GET /api/monitor/usage/tool-usage`
  - `GET /api/monitor/usage/quota/limit`
  - base derived from `ANTHROPIC_BASE_URL` for Claude Code setup.

## Options
1. CodexBar parity (quota endpoint only)
- Pros: minimal complexity, proven in a similar app, stable line mapping.
- Cons: depends on reverse-engineered behavior for auth header/shape.

2. Official z.ai plugin parity (model/tool/quota triad)
- Pros: closest to vendor-maintained examples.
- Cons: extra requests, output shape less aligned with OpenUsage line model, more failure points.

3. Hybrid (recommended)
- Quota endpoint as primary source for stable usage bars.
- Authorization fallback strategy (`Bearer <token>` first, raw token second).
- Optional host/URL overrides via `Z_AI_API_HOST` / `Z_AI_QUOTA_URL`.
- Region inference from host override and explicit `ZAI_API_REGION`.

## Decision
- Implement Option 3 (hybrid) for compatibility and resilience.
- Keep scope small: quota + plan + optional MCP detail badge/text only.

## Non-goals
- No UI settings panel changes in this PR.
- No background token bootstrap from external z.ai CLI configs.
- No new dependencies.

## Validation plan
1. Add unit tests for token/endpoint/auth fallback/shape parsing.
2. Add Rust host env allowlist coverage for new `Z_AI_*` vars.
3. Run plugin test + host API test + targeted vitest.
