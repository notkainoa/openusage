import XCTest
@testable import OpenUsage

@MainActor
final class FactoryProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-10-01T12:00:00.000Z")!
    private var liveToken: String { makeCursorJWT(exp: now.timeIntervalSince1970 + 3_600) }
    private var expiredToken: String { makeCursorJWT(exp: now.timeIntervalSince1970 - 60) }
    private let credentialsPath = FactoryAuthStore.loginKeychainCredentialsPath

    // MARK: - Mapper

    func testMapsStandardCoreAndExtraBalance() throws {
        let lines = try FactoryUsageMapper.map(Self.limitsBody, now: now)

        XCTAssertEqual(progress(lines, "Session")?.used, 12)
        XCTAssertEqual(progress(lines, "Session")?.resetsAt, OpenUsageISO8601.date(from: "2026-10-01T15:00:00.000Z"))
        XCTAssertEqual(progress(lines, "Session")?.periodDurationMs, MetricPeriod.sessionMs)
        XCTAssertEqual(progress(lines, "Weekly")?.used, 40.5)
        XCTAssertEqual(progress(lines, "Weekly")?.periodDurationMs, MetricPeriod.weekMs)
        XCTAssertEqual(progress(lines, "Monthly")?.used, 7)
        XCTAssertEqual(progress(lines, "Monthly")?.periodDurationMs, MetricPeriod.monthMs)
        XCTAssertEqual(progress(lines, "Core Weekly")?.used, 3)
        XCTAssertEqual(progress(lines, "Core Monthly")?.used, 1)
        XCTAssertEqual(dollars(lines, FactoryUsageMapper.extraBalanceLabel), 12.5)
    }

    /// Droid shows a closed or never-opened window as 0% until the next request starts one.
    func testClosedOrMissingWindowReadsAsUnused() throws {
        let lines = try FactoryUsageMapper.map(Self.limitsBody, now: now)

        let notStarted = try XCTUnwrap(progress(lines, "Core Session"))
        XCTAssertEqual(notStarted.used, 0)
        XCTAssertNil(notStarted.resetsAt)

        let later = OpenUsageISO8601.date(from: "2026-10-01T16:00:00.000Z")!
        let closed = try XCTUnwrap(progress(try FactoryUsageMapper.map(Self.limitsBody, now: later), "Session"))
        XCTAssertEqual(closed.used, 0)
        XCTAssertNil(closed.resetsAt)
    }

    func testMissingCoreAndBalanceLeaveThoseRowsEmpty() throws {
        let body = Data(#"{"limits":{"standard":{"weekly":{"usedPercent":5,"windowEnd":"2026-10-05T00:00:00Z"}}}}"#.utf8)

        let lines = try FactoryUsageMapper.map(body, now: now)

        XCTAssertEqual(lines.map(\.label), ["Weekly"])
    }

    func testRejectsResponsesWithoutStandardLimitsOrWithDriftedBuckets() {
        XCTAssertThrowsError(try FactoryUsageMapper.map(Data(#"{"limits":{}}"#.utf8), now: now)) {
            XCTAssertEqual($0 as? FactoryUsageError, .invalidResponse)
        }
        let drifted = Data(#"{"limits":{"standard":{"weekly":{"windowEnd":"2026-10-05T00:00:00Z"}}}}"#.utf8)
        XCTAssertThrowsError(try FactoryUsageMapper.map(drifted, now: now)) {
            XCTAssertEqual($0 as? FactoryUsageError, .invalidResponse)
        }
    }

    // MARK: - Provider

    func testFetchesLimitsWithOrgHeaderOnTheAccountsRegion() async throws {
        let files = FakeFiles([credentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(
            access: liveToken, organizationID: "org_1", whoami: ["region": "eu"]
        ))])
        let http = Self.limitsAndPlanClient()

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(progress(snapshot.lines, "Session")?.used, 12)
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [
            "https://api.eu.factory.ai/api/billing/limits",
            "https://api.eu.factory.ai/api/organization/managed-settings"
        ])
        for request in http.requests {
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(liveToken)")
            XCTAssertEqual(request.headers[FactoryUsageClient.organizationHeader], "org_1")
        }
    }

    func testPlanFailureKeepsUsageAndDropsBadge() async {
        let files = FakeFiles([credentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: liveToken))])
        let http = RoutingHTTPClient { request in
            if request.url == FactoryUsageClient.managedSettingsURL(region: nil) {
                return HTTPResponse(statusCode: 403, headers: [:], body: Data(#"{"error":"forbidden"}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.limitsBody)
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(progress(snapshot.lines, "Weekly")?.used, 40.5)
    }

    func testPlanNamesMatchFactorysBillingLabels() {
        func plan(_ body: String, status: Int = 200) -> String? {
            FactoryUsageMapper.planName(from: HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8)))
        }

        XCTAssertEqual(plan(#"{"success":true,"factoryTier":"team"}"#), "Pro")
        XCTAssertEqual(plan(#"{"success":true,"factoryTier":"team_annual"}"#), "Pro Annual")
        XCTAssertEqual(plan(#"{"success":true,"factoryTier":"pro_plus"}"#), "Plus")
        XCTAssertEqual(plan(#"{"success":true,"factoryTier":"max"}"#), "Max")
        XCTAssertEqual(plan(#"{"success":true,"factoryTier":"payg"}"#), "Enterprise")
        XCTAssertEqual(plan(#"{"success":true,"factoryTier":"future_tier"}"#), "Future Tier")
        XCTAssertNil(plan(#"{"success":true,"settings":null}"#))
        XCTAssertNil(plan(#"{"success":true,"factoryTier":null}"#))
        XCTAssertNil(plan(#"{"success":true,"factoryTier":"max"}"#, status: 500))
    }

    func testExpiredTokenRotatesAndWritesBackForDroid() async throws {
        let newToken = makeCursorJWT(sub: "new", exp: now.timeIntervalSince1970 + 3_600)
        let files = FakeFiles([credentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(
            access: expiredToken, refresh: "old-refresh", whoami: ["region": "global", "userId": "u1"]
        ))])
        let http = RoutingHTTPClient { request in
            if request.url == FactoryUsageClient.refreshURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"\#(newToken)","refresh_token":"new-refresh"}"#.utf8
                ))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.limitsBody)
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [
            FactoryUsageClient.refreshURL,
            FactoryUsageClient.limitsURL(region: "global"),
            FactoryUsageClient.managedSettingsURL(region: "global")
        ])
        XCTAssertEqual(
            String(data: http.requests[0].body ?? Data(), encoding: .utf8),
            "grant_type=refresh_token&refresh_token=old-refresh&client_id=\(FactoryUsageClient.clientID)"
        )
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer \(newToken)")
        let saved = try FactoryFixtures.decryptedObject(files.files[credentialsPath])
        XCTAssertEqual(saved["access_token"] as? String, newToken)
        XCTAssertEqual(saved["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual((saved["whoami"] as? [String: Any])?["userId"] as? String, "u1")
    }

    /// Droid renewed after our first read: a 401 re-reads its login and uses that token instead of
    /// spending the refresh token Droid already replaced.
    func testUsesDroidsRenewedLoginInsteadOfRefreshingAgain() async throws {
        let droidToken = makeCursorJWT(sub: "droid", exp: now.timeIntervalSince1970 + 3_600)
        let files = FakeFiles([credentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: liveToken))])
        let droidLogin = FactoryFixtures.envelope(FactoryFixtures.credentials(access: droidToken, refresh: "droid-refresh"))
        let http = RoutingHTTPClient { [liveToken, credentialsPath] request in
            if request.headers["Authorization"] == "Bearer \(liveToken)" {
                files.files[credentialsPath] = droidLogin
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.limitsBody)
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(http.requests.contains { $0.url == FactoryUsageClient.refreshURL })
        XCTAssertEqual(http.requests.dropFirst().first?.headers["Authorization"], "Bearer \(droidToken)")
        XCTAssertEqual(files.files[credentialsPath], droidLogin)
    }

    /// Droid saved a new login while our refresh request was in flight: its copy wins on disk.
    func testDroidRewritingTheLoginMidRefreshKeepsDroidsCopy() async throws {
        let newToken = makeCursorJWT(sub: "new", exp: now.timeIntervalSince1970 + 3_600)
        let files = FakeFiles([credentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: expiredToken))])
        let droidLogin = FactoryFixtures.envelope(FactoryFixtures.credentials(access: "droid", refresh: "droid-refresh"))
        let http = RoutingHTTPClient { [credentialsPath] request in
            if request.url == FactoryUsageClient.refreshURL {
                files.files[credentialsPath] = droidLogin
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"\#(newToken)","refresh_token":"new-refresh"}"#.utf8
                ))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.limitsBody)
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(files.files[credentialsPath], droidLogin)
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer \(newToken)", "this refresh still uses the new token")
    }

    func testFailedSaveStillUsesRenewedTokenForThisRefresh() async throws {
        let newToken = makeCursorJWT(sub: "new", exp: now.timeIntervalSince1970 + 3_600)
        let original = FactoryFixtures.envelope(FactoryFixtures.credentials(access: expiredToken))
        let files = FakeFiles([credentialsPath: original])
        let http = RoutingHTTPClient { request in
            if request.url == FactoryUsageClient.refreshURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"\#(newToken)","refresh_token":"new-refresh"}"#.utf8
                ))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.limitsBody)
        }

        let snapshot = await makeProvider(files: ReadOnlyFiles(files), http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer \(newToken)")
        XCTAssertEqual(files.files[credentialsPath], original)
    }

    func testUnauthorizedLimitsRefreshesOnceAndRetries() async throws {
        let newToken = makeCursorJWT(sub: "new", exp: now.timeIntervalSince1970 + 3_600)
        let files = FakeFiles([credentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: liveToken))])
        let http = RoutingHTTPClient { [liveToken] request in
            if request.url == FactoryUsageClient.refreshURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"\#(newToken)","refresh_token":"new-refresh"}"#.utf8
                ))
            }
            let unauthorized = request.headers["Authorization"] == "Bearer \(liveToken)"
            return HTTPResponse(statusCode: unauthorized ? 401 : 200, headers: [:], body: Self.limitsBody)
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 4, "limits 401, refresh, limits retry, plan")
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer \(newToken)", "the plan call uses the renewed token")
        XCTAssertEqual(try FactoryFixtures.decryptedObject(files.files[credentialsPath])["access_token"] as? String, newToken)
    }

    func testRejectedRefreshReportsSessionExpiredAndKeepsDroidsFile() async {
        let original = FactoryFixtures.envelope(FactoryFixtures.credentials(access: expiredToken))
        let files = FakeFiles([credentialsPath: original])
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(files.files[credentialsPath], original)
    }

    /// Only a 4xx rejection means the login is dead; a WorkOS outage or garbage reply must not tell
    /// the user to sign in again.
    func testRefreshOutageOrBadReplyIsNotReportedAsLogout() async {
        for (status, body, expected) in [
            (503, "", ErrorCategory.http(503)),
            (429, "", ErrorCategory.http(429)),
            (200, #"{"access_token":""}"#, ErrorCategory.decoding)
        ] {
            let original = FactoryFixtures.envelope(FactoryFixtures.credentials(access: expiredToken))
            let files = FakeFiles([credentialsPath: original])
            let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8)) }

            let snapshot = await makeProvider(files: files, http: http).refresh()

            XCTAssertEqual(snapshot.errorCategory, expected, "HTTP \(status)")
            XCTAssertEqual(files.files[credentialsPath], original)
        }
    }

    func testLimitsServerErrorTransportFailureAndDriftAreCategorized() async {
        let cases: [(@Sendable (HTTPRequest) throws -> HTTPResponse, ErrorCategory)] = [
            ({ _ in HTTPResponse(statusCode: 500, headers: [:], body: Data()) }, .http(500)),
            ({ _ in throw URLError(.notConnectedToInternet) }, .network),
            ({ _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"limits":{}}"#.utf8)) }, .decoding)
        ]
        for (handler, expected) in cases {
            let files = FakeFiles([credentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: liveToken))])

            let snapshot = await makeProvider(files: files, http: RoutingHTTPClient(handler: handler)).refresh()

            XCTAssertEqual(snapshot.errorCategory, expected)
        }
    }

    func testMissingLoginReportsNotLoggedIn() async {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Self.limitsBody) }
        let provider = makeProvider(files: FakeFiles(), http: http)

        let snapshot = await provider.refresh()
        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(hasCredentials)
    }

    func testDescriptorsMatchMapperLabels() throws {
        let provider = makeProvider(files: FakeFiles(), http: RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let labels = Set(try FactoryUsageMapper.map(Self.limitsBody, now: now).map(\.label))

        XCTAssertEqual(Set(provider.widgetDescriptors.map(\.metricLabel)), labels)
    }

    // MARK: - Helpers

    private func makeProvider(files: TextFileAccessing, http: RoutingHTTPClient) -> FactoryProvider {
        FactoryProvider(
            authStore: FactoryFixtures.store(files: files, now: now),
            usageClient: FactoryUsageClient(httpClient: http),
            now: { [now] in now }
        )
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, _, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, resetsAt, periodDurationMs)
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }

    private static func limitsAndPlanClient() -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            if request.url.path == FactoryUsageClient.managedSettingsPath {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"success":true,"settings":null,"factoryTier":"max"}"#.utf8
                ))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: limitsBody)
        }
    }

    nonisolated private static let limitsBody = Data("""
    {
      "limits": {
        "standard": {
          "fiveHour": {"usedPercent": 12, "windowEnd": "2026-10-01T15:00:00.000Z"},
          "weekly": {"usedPercent": 40.5, "windowEnd": "2026-10-05T00:00:00.000Z"},
          "monthly": {"usedPercent": 7, "windowEnd": "2026-10-20T00:00:00.000Z"}
        },
        "core": {
          "fiveHour": {"usedPercent": 0, "windowEnd": null},
          "weekly": {"usedPercent": 3, "windowEnd": "2026-10-05T00:00:00.000Z"},
          "monthly": {"usedPercent": 1, "windowEnd": "2026-10-20T00:00:00.000Z"}
        }
      },
      "extraUsageBalanceCents": 1250,
      "overagePreference": null,
      "extraUsageAllowed": true,
      "canManageOverage": true
    }
    """.utf8)
}
