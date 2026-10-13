import Foundation

/// Maps `GET /api/billing/limits`:
///
///     {"limits": {"standard": {"fiveHour": {"usedPercent": 12, "windowEnd": "…"}, "weekly": {…}, "monthly": {…}},
///                 "core": {…same buckets…}},
///      "extraUsageBalanceCents": 1250, …}
///
/// `standard` is the plan's main pool (all models); `core` is the Droid Core pool. Pure — no I/O.
enum FactoryUsageMapper {
    private struct Bucket {
        let key: String
        let label: String
        let periodMs: Int
    }

    private static let standardBuckets = [
        Bucket(key: "fiveHour", label: "Session", periodMs: MetricPeriod.sessionMs),
        Bucket(key: "weekly", label: "Weekly", periodMs: MetricPeriod.weekMs),
        Bucket(key: "monthly", label: "Monthly", periodMs: MetricPeriod.monthMs)
    ]

    private static let coreBuckets = [
        Bucket(key: "fiveHour", label: "Core Session", periodMs: MetricPeriod.sessionMs),
        Bucket(key: "weekly", label: "Core Weekly", periodMs: MetricPeriod.weekMs),
        Bucket(key: "monthly", label: "Core Monthly", periodMs: MetricPeriod.monthMs)
    ]

    static let extraBalanceLabel = "Extra usage balance"

    static func map(_ body: Data, now: Date) throws -> [MetricLine] {
        // `limits.standard` is what Droid itself requires before showing anything.
        guard let root = ProviderParse.jsonObject(body),
              let limits = root["limits"] as? [String: Any],
              let standard = limits["standard"] as? [String: Any]
        else {
            throw FactoryUsageError.invalidResponse
        }

        var lines = try poolLines(standard, buckets: standardBuckets, now: now)
        if let core = limits["core"] as? [String: Any] {
            lines += try poolLines(core, buckets: coreBuckets, now: now)
        }
        if let cents = ProviderParse.number(root["extraUsageBalanceCents"]) {
            lines.append(.values(
                label: extraBalanceLabel,
                values: [MetricValue(number: ProviderParse.centsToDollars(max(0, cents)), kind: .dollars)]
            ))
        }
        return lines.isEmpty ? [.noUsageData] : lines
    }

    /// Names from Factory's own billing UI. Its internal tier slugs don't match the marketed names
    /// (`team` is the Pro plan, `pro_plus` is Plus).
    private static let planNames: [String: String] = [
        "team": "Pro",
        "team_annual": "Pro Annual",
        "pro_plus": "Plus",
        "max": "Max",
        "ultra": "Ultra",
        "teams": "Teams",
        "business": "Business",
        "enterprise": "Enterprise",
        "payg": "Enterprise"
    ]

    /// Plan badge from `GET /api/organization/managed-settings` (`{"success": true, "factoryTier": "max", …}`).
    /// Optional by design: any failure just leaves the card without a badge.
    static func planName(from response: HTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let tier = (body["factoryTier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tier.isEmpty
        else {
            return nil
        }
        return planNames[tier.lowercased()] ?? tier.titleCased(separator: { $0 == "_" })
    }

    private static func poolLines(_ pool: [String: Any], buckets: [Bucket], now: Date) throws -> [MetricLine] {
        try buckets.compactMap { bucket in
            guard let raw = pool[bucket.key], !(raw is NSNull) else { return nil }
            guard let entry = raw as? [String: Any] else { throw FactoryUsageError.invalidResponse }
            return try line(entry, bucket: bucket, now: now)
        }
    }

    /// Droid shows a bucket whose window is missing or already closed as 0% ("Use Droid to start"):
    /// the next request opens a fresh window. Mirror that instead of showing the stale percentage.
    private static func line(_ entry: [String: Any], bucket: Bucket, now: Date) throws -> MetricLine {
        let windowEnd = date(entry["windowEnd"])
        guard let windowEnd, windowEnd > now else {
            return .progress(label: bucket.label, used: 0, limit: 100, format: .percent,
                             periodDurationMs: bucket.periodMs)
        }
        // An open window without a number is schema drift, not an unused pool.
        guard let usedPercent = ProviderParse.number(entry["usedPercent"]) else {
            throw FactoryUsageError.invalidResponse
        }
        return .progress(
            label: bucket.label,
            used: ProviderParse.clampPercent(usedPercent),
            limit: 100,
            format: .percent,
            resetsAt: windowEnd,
            periodDurationMs: bucket.periodMs
        )
    }

    /// Droid parses `windowEnd` with `new Date(…)`, so accept ISO strings and epoch milliseconds.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            return OpenUsageISO8601.date(from: text)
        }
        if let milliseconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return nil
    }
}
