# Z.AI

> API behavior inferred from official z.ai plugin examples and live endpoint behavior. May change without notice.

## Overview

- **Protocol:** REST (plain JSON)
- **Global host:** `https://api.z.ai`
- **Primary endpoint:** `GET /api/monitor/usage/quota/limit`
- **Auth:** API token from OpenUsage Settings (`zaiApiKey`)

## Setup

Set your token in the app:
1. Open `Settings`
2. Enable `Z.AI` plugin
3. Paste key into `Z.AI -> API key` field

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
| Missing token | `Missing API token. Set Z.AI API key in OpenUsage Settings.` |
| 401/403 | `Token invalid. Check your Z.AI API key.` |
| Success without limits payload | `No usage data returned by Z.AI. You may not have an active subscription. ...` |
| HTTP error | `Usage request failed (HTTP {status}). Try again later.` |
| Invalid JSON | `Usage response invalid. Try again later.` |
