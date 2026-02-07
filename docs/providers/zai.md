# Z.AI

> API behavior inferred from official z.ai plugin examples and live endpoint behavior. May change without notice.

## Overview

- **Protocol:** REST (plain JSON)
- **Global host:** `https://api.z.ai`
- **China mainland host:** `https://open.bigmodel.cn`
- **Primary endpoint:** `GET /api/monitor/usage/quota/limit`
- **Auth:** API token from environment (`Z_AI_API_KEY`)

## Setup

OpenUsage resolves Z.AI token in this order:

1. `Z_AI_API_KEY` process env
2. OpenUsage app setting `zaiApiKey` (Settings -> Z.AI -> API key)
3. Claude settings auto-detect (`~/.claude/settings.json` / `~/.claude/settings.local.json`)
   - `env.Z_AI_API_KEY`
   - `env.ANTHROPIC_AUTH_TOKEN` or `env.ANTHROPIC_API_KEY` when `env.ANTHROPIC_BASE_URL` points to z.ai / bigmodel

Set via env if preferred:

```bash
export Z_AI_API_KEY="your-z-ai-token"
```

Optional endpoint overrides:

```bash
# Host/base override (path auto-appended when missing)
export Z_AI_API_HOST="open.bigmodel.cn"

# Full quota URL override (used exactly as provided)
export Z_AI_QUOTA_URL="https://open.bigmodel.cn/api/coding/paas/v4"

# Optional region hint: global | bigmodel-cn | cn
export ZAI_API_REGION="bigmodel-cn"
```

## API

### GET /api/monitor/usage/quota/limit

**Headers**

| Header | Value |
|---|---|
| `authorization` | `Bearer <token>` (fallback to raw token if rejected) |
| `accept` | `application/json` |

**Example response shape**

```jsonc
{
  "code": 200,
  "success": true,
  "data": {
    "planName": "Pro",
    "limits": [
      {
        "type": "TOKENS_LIMIT",
        "unit": 3,
        "number": 5,
        "usage": 40000000,
        "currentValue": 13628365,
        "remaining": 26371635,
        "percentage": 34,
        "nextResetTime": 1768507567547
      },
      {
        "type": "TIME_LIMIT",
        "unit": 1,
        "number": 30,
        "usage": 100,
        "currentValue": 20,
        "remaining": 80,
        "percentage": 20
      }
    ]
  }
}
```

## Displayed lines

| Line | Description |
|---|---|
| Tokens | Token window usage (primary tray metric) |
| MCP | Tool/time usage window |

## Error messages

| Condition | Message |
|---|---|
| Missing token | `Missing API token. Set Z.AI API key in OpenUsage Settings, Z_AI_API_KEY env, or ~/.claude/settings.json.` |
| 401/403 | `Token invalid. Check your Z.AI API key.` |
| Success without limits payload | `No usage data returned by Z.AI. You may not have an active subscription. ...` |
| HTTP error | `Usage request failed (HTTP {status}). Try again later.` |
| Invalid JSON | `Usage response invalid. Try again later.` |
