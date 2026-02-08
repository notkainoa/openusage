# Z.AI settings visibility

Date: 2026-02-07

## Goal
- Show Z.AI API key settings only when Z.AI plugin is enabled.
- Place Z.AI section below Plugins in Settings UI.

## Behavior
- Compute visibility from `plugins` list in Settings page.
- Render Z.AI section iff plugin with `id === "zai"` is enabled.
- Preserve existing API key input behavior/callbacks.

## Validation
- Settings page test: hidden when Z.AI disabled/not present.
- Settings page test: shown when Z.AI enabled.
