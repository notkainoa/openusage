# Factory

Tracks your Factory (Droid) usage limits using the login from the Droid CLI. These are the same numbers Droid shows on its Usage & Limits screen.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Standard Usage used in the current 5-hour window, with its reset countdown |
| Weekly | Standard Usage used this week |
| Monthly | Standard Usage used this month |
| Core Session / Core Weekly / Core Monthly | The same three windows for the Droid Core pool (on demand by default) |
| Extra Balance | Your prepaid Extra Usage balance in dollars (on demand by default) |

Standard Usage covers every model and is used first. Droid Core is a separate pool for Droid Core models (such as GLM, Kimi, DeepSeek, and MiniMax) that stays available after Standard runs out. Work on a Core model, including models picked by Droid's automatic routing, counts toward the Core rows even while Standard has room.

The card's plan badge shows your Factory plan (Pro, Plus, Max, Ultra, Teams, Business, or Enterprise), using the same names as Factory's billing page. If the plan can't be read, the badge is hidden and the usage rows still load.

A window that hasn't started yet, or has already ended, shows 0% with no reset time. Droid does the same: the next request opens a new window. A Session row in that state reads "Not started".

## Where credentials come from

Sign in once with the Droid CLI (`droid`). OpenUsage reads the login Droid saved in `~/.factory`, in Droid's own order:

1. `~/.factory/auth.v2.loginkeychain`, unlocked with the `Factory CLI` key in your login Keychain (Droid's default on macOS)
2. `~/.factory/auth.v2.file`, unlocked with `~/.factory/auth.v2.key` (Droid's fallback when the Keychain isn't available)

Droid's sign-in lasts about a day, and Droid renews it whenever you use it, so OpenUsage usually just reads Droid's current login. If it has expired, OpenUsage renews it and saves the new login back into the same file, so Droid stays signed in. If Droid already renewed the login, OpenUsage uses Droid's copy instead of renewing it again, and it never overwrites a login Droid saved while OpenUsage was renewing.

## Troubleshooting

- **"Factory not logged in"**: run `droid` and sign in, then refresh.
- **"Factory session expired"**: Factory rejected the saved login. Run `droid` and sign in again.
- **"Couldn't read Droid's login key from the Keychain"**: your login Keychain is locked or blocked access. Unlock it, then refresh.
- **"Couldn't read Droid's saved login"**: the file in `~/.factory` couldn't be decrypted. Signing in again with `droid` rewrites it.
- **Core rows or Extra Balance show "No data"**: your plan doesn't report that pool or balance.

## Under the hood

`GET https://api.factory.ai/api/billing/limits` (or `api.eu.factory.ai` for EU accounts), with the `X-Factory-Org-Id` header when Droid has an active organization saved. This is the same call Droid makes. The plan comes from `GET /api/organization/managed-settings` (its `factoryTier` field), the call Droid uses to learn the org's tier. Tokens renew through WorkOS (`api.workos.com/user_management/authenticate`) with Droid's client ID. A 401/403 triggers one renewal and retry.
