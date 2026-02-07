import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const makeQuotaResponse = (overrides = {}) =>
  JSON.stringify({
    code: 200,
    success: true,
    data: {
      planName: "Pro",
      limits: [
        {
          type: "TOKENS_LIMIT",
          unit: 3,
          number: 5,
          usage: 40000000,
          currentValue: 13628365,
          remaining: 26371635,
          percentage: 34,
          nextResetTime: 1768507567547,
        },
        {
          type: "TIME_LIMIT",
          unit: 1,
          number: 30,
          usage: 100,
          currentValue: 20,
          remaining: 80,
          percentage: 20,
          usageDetails: [{ modelCode: "search-prime", usage: 95 }],
        },
      ],
    },
    ...overrides,
  })

describe("zai plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when token is missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Missing API token")
  })

  it("surfaces subscription guidance when response has no limits payload", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "Z_AI_API_KEY" ? "zai-token" : null))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({ code: 200, success: true, msg: "Operation successful" }),
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("active subscription")
  })

  it("uses token from OpenUsage settings when env is missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      "/tmp/openusage-test/settings.json",
      JSON.stringify({ zaiApiKey: "stored-token" })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.authorization).toBe("Bearer stored-token")
      return { status: 200, headers: {}, bodyText: makeQuotaResponse() }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("uses token from ~/.claude/settings.json env.Z_AI_API_KEY", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      "~/.claude/settings.json",
      JSON.stringify({ env: { Z_AI_API_KEY: "claude-zai-token" } })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.authorization).toBe("Bearer claude-zai-token")
      return { status: 200, headers: {}, bodyText: makeQuotaResponse() }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("uses anthropic token from Claude settings when base URL is z.ai and infers host", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      "~/.claude/settings.json",
      JSON.stringify({
        env: {
          ANTHROPIC_AUTH_TOKEN: "anth-token",
          ANTHROPIC_BASE_URL: "https://open.bigmodel.cn/api/anthropic/v1",
        },
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.url).toBe("https://open.bigmodel.cn/api/monitor/usage/quota/limit")
      expect(opts.headers.authorization).toBe("Bearer anth-token")
      return { status: 200, headers: {}, bodyText: makeQuotaResponse() }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("does not use anthropic token when Claude base URL is not z.ai", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      "~/.claude/settings.json",
      JSON.stringify({
        env: {
          ANTHROPIC_AUTH_TOKEN: "anth-token",
          ANTHROPIC_BASE_URL: "https://api.anthropic.com",
        },
      })
    )

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Missing API token")
  })

  it("uses global quota endpoint by default with bearer auth", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "Z_AI_API_KEY" ? "zai-token" : null))

    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.url).toBe("https://api.z.ai/api/monitor/usage/quota/limit")
      expect(opts.headers.authorization).toBe("Bearer zai-token")
      return { status: 200, headers: {}, bodyText: makeQuotaResponse() }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    expect(result.lines.find((line) => line.label === "Tokens")).toBeTruthy()
  })

  it("uses Z_AI_API_HOST and appends quota path when host has no path", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "Z_AI_API_KEY") return "zai-token"
      if (name === "Z_AI_API_HOST") return "open.bigmodel.cn"
      return null
    })

    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.url).toBe("https://open.bigmodel.cn/api/monitor/usage/quota/limit")
      return { status: 200, headers: {}, bodyText: makeQuotaResponse() }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("uses Z_AI_QUOTA_URL override exactly", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "Z_AI_API_KEY") return "zai-token"
      if (name === "Z_AI_QUOTA_URL") return "https://open.bigmodel.cn/api/coding/paas/v4"
      return null
    })

    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.url).toBe("https://open.bigmodel.cn/api/coding/paas/v4")
      return { status: 200, headers: {}, bodyText: makeQuotaResponse() }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("retries with raw token when bearer auth is rejected", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "Z_AI_API_KEY" ? "zai-token" : null))

    let requestCount = 0
    ctx.host.http.request.mockImplementation((opts) => {
      requestCount += 1
      if (requestCount === 1) {
        expect(opts.headers.authorization).toBe("Bearer zai-token")
        return { status: 401, headers: {}, bodyText: "{}" }
      }
      expect(opts.headers.authorization).toBe("zai-token")
      return { status: 200, headers: {}, bodyText: makeQuotaResponse() }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(requestCount).toBe(2)
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("maps token/time limits to progress lines with pacing", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "Z_AI_API_KEY" ? "zai-token" : null))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: makeQuotaResponse(),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const tokens = result.lines.find((line) => line.label === "Tokens")
    const mcp = result.lines.find((line) => line.label === "MCP")
    expect(tokens).toBeTruthy()
    expect(mcp).toBeTruthy()
    expect(tokens.limit).toBe(100)
    expect(tokens.periodDurationMs).toBe(5 * 60 * 60 * 1000)
    expect(tokens.resetsAt).toBe(new Date(1768507567547).toISOString())
    expect(mcp.periodDurationMs).toBe(30 * 24 * 60 * 60 * 1000)
  })

  it("surfaces API error messages from response envelope", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "Z_AI_API_KEY" ? "zai-token" : null))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({ code: 1001, success: false, msg: "Authorization Token Missing" }),
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Authorization Token Missing")
  })

  it("throws on invalid JSON", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "Z_AI_API_KEY" ? "zai-token" : null))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: "not-json",
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })
})
