# Z.AI key resolution and UX

Date: 2026-02-07

## Goal
- Remove "missing API key" ambiguity for real users.
- Support two setup flows:
  - Auto-detect from Claude Code settings when available.
  - Manual API key input in OpenUsage settings.

## Requirements
- Resolve Z.AI token in this priority order:
  1. Process env `Z_AI_API_KEY`.
  2. OpenUsage settings store (`zaiApiKey`).
  3. Claude settings files (`~/.claude/settings.json`, `~/.claude/settings.local.json`):
     - `env.Z_AI_API_KEY` directly.
     - `env.ANTHROPIC_AUTH_TOKEN` (or `env.ANTHROPIC_API_KEY`) only when `env.ANTHROPIC_BASE_URL` points to z.ai / bigmodel.
- Keep existing endpoint override behavior (`Z_AI_QUOTA_URL`, `Z_AI_API_HOST`, `ZAI_API_REGION`).
- If Claude settings provide z.ai host/base info, use it as fallback host/region source when env overrides are absent.

## UI
- Add "Z.AI API Key" field to Settings page.
- Persist in `settings.json` as `zaiApiKey`.
- Changing key should trigger immediate `zai` reprobe when plugin enabled.

## Validation
1. Plugin tests: env precedence, app-settings fallback, Claude settings fallback, anthropic-token guard by base URL.
2. Settings lib tests: load/save/trim of `zaiApiKey`.
3. Settings page test: renders field + dispatches change callback.
4. App tests: mock new settings loaders/savers.
