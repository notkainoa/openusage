(function () {
  const QUOTA_PATH = "/api/monitor/usage/quota/limit"
  const DEFAULT_TIME_LIMIT_MS = 30 * 24 * 60 * 60 * 1000
  const OPENUSAGE_SETTINGS_FILE = "settings.json"
  const NO_USAGE_GUIDANCE =
    "No usage data returned by Z.AI. You may not have an active subscription. Try: check your Z.AI plan limits, verify this API key belongs to that subscribed account, and if using Claude Code + z.ai confirm ANTHROPIC_BASE_URL targets api.z.ai or open.bigmodel.cn."
  const CLAUDE_SETTINGS_PATHS = [
    "~/.config/claude/settings.json",
    "~/.claude/settings.json",
    "~/.claude/settings.local.json",
  ]

  const REGIONS = {
    global: "https://api.z.ai",
    "bigmodel-cn": "https://open.bigmodel.cn",
  }

  function clean(value) {
    if (value === null || value === undefined) return null
    let s = String(value).trim()
    if (!s) return null
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
      s = s.slice(1, -1).trim()
    }
    return s || null
  }

  function readEnv(ctx, name) {
    if (!ctx.host.env || typeof ctx.host.env.get !== "function") return null
    try {
      return clean(ctx.host.env.get(name))
    } catch (e) {
      ctx.host.log.warn("env read failed for " + name + ": " + String(e))
      return null
    }
  }

  function normalizeUrl(raw) {
    const cleaned = clean(raw)
    if (!cleaned) return null
    if (/^https?:\/\//i.test(cleaned)) return cleaned
    return "https://" + cleaned
  }

  function resolveExplicitUrl(raw) {
    const normalized = normalizeUrl(raw)
    if (!normalized) return null
    try {
      return new URL(normalized).toString()
    } catch {
      return null
    }
  }

  function resolveHostUrl(raw) {
    const normalized = normalizeUrl(raw)
    if (!normalized) return null
    try {
      const url = new URL(normalized)
      const pathname = (url.pathname || "/").replace(/\/+$/, "")
      if (!pathname || pathname === "/") {
        url.pathname = QUOTA_PATH
      }
      return url.toString()
    } catch {
      return null
    }
  }

  function readJsonFile(ctx, path) {
    if (!path) return null
    if (!ctx.host.fs || typeof ctx.host.fs.readText !== "function") return null
    if (typeof ctx.host.fs.exists === "function" && !ctx.host.fs.exists(path)) return null
    try {
      const content = ctx.host.fs.readText(path)
      return ctx.util.tryParseJson(content)
    } catch (e) {
      ctx.host.log.warn("json read failed for " + path + ": " + String(e))
      return null
    }
  }

  function readStringField(obj, key) {
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null
    return clean(obj[key])
  }

  function resolveOpenUsageSettingsPath(ctx) {
    const appDataDir = clean(ctx.app && ctx.app.appDataDir)
    if (!appDataDir) return null
    return appDataDir.replace(/\/+$/, "") + "/" + OPENUSAGE_SETTINGS_FILE
  }

  function resolveTokenFromAppSettings(ctx) {
    const path = resolveOpenUsageSettingsPath(ctx)
    if (!path) return null
    const settings = readJsonFile(ctx, path)
    return readStringField(settings, "zaiApiKey")
  }

  function isZaiBaseUrl(raw) {
    const normalized = normalizeUrl(raw)
    if (!normalized) return false
    try {
      const host = new URL(normalized).hostname.toLowerCase()
      return host === "api.z.ai" || host.endsWith(".z.ai") || host.includes("bigmodel.cn")
    } catch {
      return false
    }
  }

  function resolveOrigin(raw) {
    const normalized = normalizeUrl(raw)
    if (!normalized) return null
    try {
      return new URL(normalized).origin
    } catch {
      return null
    }
  }

  function resolveClaudeSettings(ctx) {
    const mergedEnv = {}
    let foundEnv = false

    for (const path of CLAUDE_SETTINGS_PATHS) {
      const parsed = readJsonFile(ctx, path)
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) continue
      const env = parsed.env
      if (!env || typeof env !== "object" || Array.isArray(env)) continue
      for (const [key, value] of Object.entries(env)) {
        mergedEnv[key] = value
      }
      foundEnv = true
    }

    if (!foundEnv) return null

    const baseUrl = readStringField(mergedEnv, "ANTHROPIC_BASE_URL")
    const anthropicToken =
      readStringField(mergedEnv, "ANTHROPIC_AUTH_TOKEN") ||
      readStringField(mergedEnv, "ANTHROPIC_API_KEY")
    const baseIsZai = isZaiBaseUrl(baseUrl)

    return {
      token:
        readStringField(mergedEnv, "Z_AI_API_KEY") ||
        (baseIsZai ? anthropicToken : null),
      quotaUrl: readStringField(mergedEnv, "Z_AI_QUOTA_URL"),
      host:
        readStringField(mergedEnv, "Z_AI_API_HOST") ||
        (baseIsZai ? resolveOrigin(baseUrl) : null),
      region: readStringField(mergedEnv, "ZAI_API_REGION"),
    }
  }

  function inferRegion(regionHint, hostOverride) {
    if (regionHint) {
      const lower = regionHint.toLowerCase()
      if (lower === "bigmodel-cn" || lower === "cn" || lower.includes("bigmodel")) {
        return "bigmodel-cn"
      }
    }
    if (hostOverride && hostOverride.toLowerCase().includes("bigmodel.cn")) {
      return "bigmodel-cn"
    }
    return "global"
  }

  function resolveQuotaUrl(ctx, claudeSettings) {
    const quotaUrlOverride =
      readEnv(ctx, "Z_AI_QUOTA_URL") || (claudeSettings && claudeSettings.quotaUrl)
    if (quotaUrlOverride) {
      const explicit = resolveExplicitUrl(quotaUrlOverride)
      if (explicit) return explicit
    }

    const hostOverride =
      readEnv(ctx, "Z_AI_API_HOST") || (claudeSettings && claudeSettings.host)
    if (hostOverride) {
      const hostUrl = resolveHostUrl(hostOverride)
      if (hostUrl) return hostUrl
    }

    const regionHint =
      readEnv(ctx, "ZAI_API_REGION") || (claudeSettings && claudeSettings.region)
    const region = inferRegion(regionHint, hostOverride)
    return REGIONS[region] + QUOTA_PATH
  }

  function resolveApiToken(ctx, claudeSettings) {
    return (
      readEnv(ctx, "Z_AI_API_KEY") ||
      resolveTokenFromAppSettings(ctx) ||
      (claudeSettings && claudeSettings.token)
    )
  }

  function readNumber(value) {
    const n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function clampPercent(value) {
    return Math.max(0, Math.min(100, value))
  }

  function readUsedPercent(limit) {
    const usage = readNumber(limit.usage)
    const remaining = readNumber(limit.remaining)
    const currentValue = readNumber(limit.currentValue)

    if (usage !== null && usage > 0) {
      const usedFromRemaining = remaining !== null ? usage - remaining : null
      let used = null

      if (usedFromRemaining !== null && currentValue !== null) {
        used = Math.max(usedFromRemaining, currentValue)
      } else if (usedFromRemaining !== null) {
        used = usedFromRemaining
      } else if (currentValue !== null) {
        used = currentValue
      }

      if (used !== null) {
        used = Math.max(0, Math.min(usage, used))
        return clampPercent((used / usage) * 100)
      }
    }

    const percentage = readNumber(limit.percentage)
    if (percentage !== null) return clampPercent(percentage)
    return null
  }

  function readWindowMinutes(limit) {
    const number = readNumber(limit.number)
    const unit = readNumber(limit.unit)
    if (number === null || number <= 0 || unit === null) return null
    if (unit === 5) return number
    if (unit === 3) return number * 60
    if (unit === 1) return number * 24 * 60
    return null
  }

  function readResetIso(ctx, limit) {
    const nextResetTime = readNumber(limit.nextResetTime)
    if (nextResetTime === null) return null
    return ctx.util.toIso(nextResetTime)
  }

  function makeProgressLine(ctx, label, limit, fallbackPeriodMs) {
    const usedPercent = readUsedPercent(limit)
    if (usedPercent === null) return null

    const line = {
      label: label,
      used: usedPercent,
      limit: 100,
      format: { kind: "percent" },
    }

    const resetsAt = readResetIso(ctx, limit)
    if (resetsAt) line.resetsAt = resetsAt

    const windowMinutes = readWindowMinutes(limit)
    if (windowMinutes !== null) {
      line.periodDurationMs = windowMinutes * 60 * 1000
    } else if (fallbackPeriodMs) {
      line.periodDurationMs = fallbackPeriodMs
    }

    return ctx.line.progress(line)
  }

  function findLimit(limits, type) {
    for (const limit of limits) {
      if (String(limit.type || "").toUpperCase() === type) return limit
    }
    return null
  }

  function parseEnvelope(body) {
    if (!body || typeof body !== "object") return { plan: null, limits: [] }

    const success = body.success
    const code = readNumber(body.code)
    if (success === false || (code !== null && code !== 0 && code !== 200)) {
      const message = clean(body.msg || body.message || "API error")
      throw message || "API error"
    }

    const data = body.data && typeof body.data === "object" ? body.data : body
    const plan =
      clean(data.planName) ||
      clean(data.plan) ||
      clean(data.plan_type) ||
      clean(data.packageName) ||
      null
    const limits = Array.isArray(data.limits) ? data.limits : []

    return { plan, limits }
  }

  function requestQuota(ctx, token, quotaUrl) {
    const requestOnce = (authorization) =>
      ctx.util.request({
        method: "GET",
        url: quotaUrl,
        headers: {
          authorization: authorization,
          accept: "application/json",
        },
        timeoutMs: 10000,
      })

    let response
    try {
      response = requestOnce("Bearer " + token)
    } catch (e) {
      ctx.host.log.error("quota request failed: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(response.status)) {
      try {
        response = requestOnce(token)
      } catch (e) {
        ctx.host.log.error("quota request retry failed: " + String(e))
        throw "Usage request failed. Check your connection."
      }
    }

    if (ctx.util.isAuthStatus(response.status)) {
      throw "Token invalid. Check your Z.AI API key."
    }

    if (response.status < 200 || response.status >= 300) {
      throw "Usage request failed (HTTP " + String(response.status) + "). Try again later."
    }

    const parsed = ctx.util.tryParseJson(response.bodyText)
    if (parsed === null) {
      throw "Usage response invalid. Try again later."
    }

    return parsed
  }

  function probe(ctx) {
    const claudeSettings = resolveClaudeSettings(ctx)
    const token = resolveApiToken(ctx, claudeSettings)
    if (!token) {
      throw "Missing API token. Set Z.AI API key in OpenUsage Settings, Z_AI_API_KEY env, or ~/.claude/settings.json."
    }

    const quotaUrl = resolveQuotaUrl(ctx, claudeSettings)
    const envelope = requestQuota(ctx, token, quotaUrl)

    let parsed
    try {
      parsed = parseEnvelope(envelope)
    } catch (e) {
      const msg = typeof e === "string" ? e : "API error"
      throw "Usage request failed: " + msg
    }

    const tokenLimit = findLimit(parsed.limits, "TOKENS_LIMIT")
    const timeLimit = findLimit(parsed.limits, "TIME_LIMIT")

    const lines = []
    if (tokenLimit) {
      const line = makeProgressLine(ctx, "Tokens", tokenLimit, null)
      if (line) lines.push(line)
    }
    if (timeLimit) {
      const line = makeProgressLine(ctx, "MCP", timeLimit, DEFAULT_TIME_LIMIT_MS)
      if (line) lines.push(line)
    }

    if (lines.length === 0) {
      throw NO_USAGE_GUIDANCE
    }

    return { plan: parsed.plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "zai", probe: probe }
})()
