# Z.AI Claude top-level settings parsing

Date: 2026-02-08

## Goal
- Ensure Z.AI auto-detect works when `~/.claude/settings.json` stores auth fields at the root level (no `env` object).

## Problem
- Some Claude installs write:
  - `ANTHROPIC_AUTH_TOKEN`
  - `ANTHROPIC_BASE_URL`
  directly at top-level in `settings.json`.
- Resolver logic that reads only `settings.env` misses these values and raises `Missing API token`.

## Behavior
- While reading each Claude settings file:
  1. Use `settings.env` when it exists and is an object.
  2. Otherwise treat the parsed top-level object as the candidate env map.
- Apply existing z.ai guards unchanged:
  - allow anthropic token only when base URL points to `z.ai` or `bigmodel.cn`.

## Validation
1. Regression test with top-level `ANTHROPIC_AUTH_TOKEN` + z.ai `ANTHROPIC_BASE_URL`.
2. Existing Claude settings tests continue to pass.
