# Z.AI manual key only

Date: 2026-02-08

## Goal
- Keep Z.AI auth source simple: only the API key entered in OpenUsage Settings.

## Behavior
- Remove Claude settings auto-detection (`~/.claude/settings*.json`).
- Remove Z.AI env-key detection (`Z_AI_API_KEY`).
- Resolve token only from OpenUsage settings store key `zaiApiKey`.
- Keep quota endpoint fixed at `https://api.z.ai/api/monitor/usage/quota/limit`.
- Update user copy/error text to reference Settings-only key entry.

## Validation
1. Plugin tests verify missing-token behavior when only Claude/env keys exist.
2. Plugin tests verify success path with stored `zaiApiKey`.
3. Settings UI text no longer mentions Claude auto-detection.
