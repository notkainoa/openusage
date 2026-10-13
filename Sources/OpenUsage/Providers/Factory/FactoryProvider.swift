import Foundation

@MainActor
final class FactoryProvider: ProviderRuntime {
    let provider = Provider(
        id: "factory",
        displayName: "Factory",
        icon: .providerMark("factory"),
        links: [
            .init(label: "Usage", url: "https://app.factory.ai/settings/usage"),
            .init(label: "Dashboard", url: "https://app.factory.ai/settings/billing")
        ]
    )

    let authStore: FactoryAuthStore
    let usageClient: FactoryUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: FactoryAuthStore = FactoryAuthStore(),
        usageClient: FactoryUsageClient = FactoryUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // Droid only opens a five-hour window on the first request, so a missing `windowEnd` is
            // the "not started" signal (the mapper drops it for closed windows too).
            .percent(id: "factory.session", provider: provider, title: "Session",
                     sessionStartSignal: .missingResetDate)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "factory.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "factory.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "percent"),
            // The Droid Core pool keeps Core-labeled models available once Standard runs out; seeded
            // On Demand (below the caret) and unpinned in `DefaultLayout`.
            .percent(id: "factory.coreSession", provider: provider, title: "Core Session",
                     sessionStartSignal: .missingResetDate)
                .exportingLimit("coreSession", unit: "percent"),
            .percent(id: "factory.coreWeekly", provider: provider, title: "Core Weekly")
                .exportingLimit("coreWeekly", unit: "percent"),
            .percent(id: "factory.coreMonthly", provider: provider, title: "Core Monthly")
                .exportingLimit("coreMonthly", unit: "percent"),
            .dollarBalance(id: "factory.extra", provider: provider, title: "Extra Balance",
                           metricLabel: FactoryUsageMapper.extraBalanceLabel, valueWord: "left")
                .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasCredentialMaterial() }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            return try await loadAndFetch()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadAndFetch() async throws -> ProviderSnapshot {
        guard var state = try await loadOffMainActor({ [authStore] in try authStore.load() }) else {
            throw FactoryAuthError.notLoggedIn
        }
        if authStore.isExpired(state.credentials.accessToken) {
            state = try await renew(state)
        }

        let response = try await ProviderAuthRetry.fetch(
            token: state.credentials.accessToken,
            attempt: { [state] token in
                try await self.usageClient.fetchLimits(
                    accessToken: token,
                    organizationID: state.credentials.organizationID,
                    region: state.credentials.region
                )
            },
            refreshAccessToken: {
                state = try await self.renew(state)
                return state.credentials.accessToken
            },
            connectionFailed: FactoryUsageError.connectionFailed,
            authExpired: FactoryAuthError.sessionExpired
        )
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: FactoryAuthError.sessionExpired,
            requestFailed: FactoryUsageError.requestFailed
        )
        let lines = try FactoryUsageMapper.map(response.body, now: now())
        let plan = await fetchPlanName(state.credentials)
        return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: now())
    }

    private func fetchPlanName(_ credentials: FactoryCredentials) async -> String? {
        do {
            let response = try await usageClient.fetchManagedSettings(
                accessToken: credentials.accessToken,
                organizationID: credentials.organizationID,
                region: credentials.region
            )
            guard let plan = FactoryUsageMapper.planName(from: response) else {
                AppLog.debug(LogTag.plugin("factory"), "plan unavailable from managed settings (HTTP \(response.statusCode))")
                return nil
            }
            return plan
        } catch {
            AppLog.debug(LogTag.plugin("factory"), "plan request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rotate the WorkOS tokens and save them back for Droid. Re-reads first so a login Droid already
    /// renewed is used as-is instead of spending a refresh token Droid has replaced.
    private func renew(_ state: FactoryAuthState) async throws -> FactoryAuthState {
        var working = state
        if let latest = try await loadOffMainActor({ [authStore] in try authStore.load() }),
           latest.envelope != state.envelope {
            if latest.credentials.accessToken != state.credentials.accessToken,
               !authStore.isExpired(latest.credentials.accessToken) {
                AppLog.debug(LogTag.auth("factory"), "Droid already rotated its login; using its token")
                return latest
            }
            working = latest
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.refreshToken(working.credentials.refreshToken)
        } catch {
            AppLog.warn(LogTag.auth("factory"), "token refresh request failed (transport): \(error.localizedDescription)")
            throw FactoryUsageError.connectionFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.auth("factory"), "token refresh failed (HTTP \(response.statusCode))")
            if (400..<500).contains(response.statusCode), response.statusCode != 429 {
                throw FactoryAuthError.sessionExpired
            }
            throw FactoryUsageError.requestFailed(response.statusCode)
        }
        guard let decoded = usageClient.decodeRefreshResponse(response) else {
            AppLog.warn(LogTag.auth("factory"), "token refresh returned an undecodable response")
            throw FactoryUsageError.invalidResponse
        }

        var refreshed = working.credentials
        refreshed.accessToken = decoded.accessToken
        refreshed.refreshToken = decoded.refreshToken
        // Fail loudly: the old refresh token is now spent, so a lost save logs Droid out. The new
        // token still works for this refresh, so log and continue rather than fail the fetch.
        do {
            let target = working
            if let saved = try await loadOffMainActor({ [authStore, refreshed] in
                try authStore.save(refreshed, over: target)
            }) {
                AppLog.info(LogTag.auth("factory"), "token refresh ok (rotated)")
                return saved
            }
            AppLog.error(LogTag.auth("factory"), "Droid's saved login changed during refresh; using the refreshed token for this session only")
        } catch {
            AppLog.error(LogTag.auth("factory"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        working.credentials = refreshed
        return working
    }
}
