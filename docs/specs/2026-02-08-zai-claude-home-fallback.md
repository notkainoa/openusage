# Z.AI Claude HOME fallback

Date: 2026-02-08

## Goal
- Ensure Claude settings auto-detection still works if runtime `~` expansion fails unexpectedly.

## Behavior
- Keep existing `~` Claude settings paths.
- Add absolute-path fallbacks built from:
  - env `HOME`
  - env `XDG_CONFIG_HOME`
- Deduplicate path candidates before reading.

## Host API
- Allow plugin env reads for `HOME` and `XDG_CONFIG_HOME`.

## Validation
1. Plugin test: HOME absolute path fallback resolves `Z_AI_API_KEY`.
2. Existing Claude settings tests remain green.
