# Z.AI key validation feedback

Date: 2026-02-08

## Goal
- Avoid probe churn while typing Z.AI API key.
- Provide immediate visual key-check status in Settings.

## Behavior
- Debounce key-save + reprobe trigger from Settings input changes.
- If Z.AI plugin is enabled:
  - show checking state while probe is in flight,
  - show success state when probe returns non-error output,
  - show error state when probe returns error output, probe start fails, or check times out.
- Keep existing provider probe flow; no new backend command.

## Defaults
- Debounce: 300ms after last keystroke.
- Timeout: 15s waiting for Z.AI probe result.
- Status copy:
  - checking: `Checking API key...`
  - success: `API key verified.`
  - error fallback: `API key check failed. Try again.`

## Validation
1. Settings page tests for checking/success/error status UI.
2. App test for key-change check lifecycle: checking -> success/error.
3. App test for debounced reprobe trigger.
