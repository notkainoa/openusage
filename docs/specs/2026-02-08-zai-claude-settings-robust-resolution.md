# Z.AI Claude settings robust resolution

Date: 2026-02-08

## Goal
- Prevent false `Missing API token` when Claude settings exist but multiple settings files conflict.

## Problem
- Current logic merges `env` across Claude settings files, then evaluates token/base-url once.
- Mixed values across files can invalidate otherwise usable token setup.

## Behavior
- Resolve Claude settings per file (not merged), in explicit priority order:
  1. `~/.claude/settings.local.json`
  2. `~/.claude/settings.json`
  3. `~/.config/claude/settings.local.json`
  4. `~/.config/claude/settings.json`
- For each file, derive candidates from that same file only:
  - token: `Z_AI_API_KEY` or (`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_API_KEY` when `ANTHROPIC_BASE_URL` is z.ai/bigmodel)
  - quota URL / host / region candidates
- Take first non-empty candidate by priority.

## Validation
1. Existing tests still pass for `~/.claude/settings.json` token and anthropic fallback.
2. New regression test: conflicting lower-priority Claude file must not cancel valid higher-priority file.
3. New regression test: reads from `~/.claude/settings.local.json` when present.
