import Foundation

struct FactoryRefreshResponse: Decodable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

enum FactoryUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Factory usage request failed. Check your connection."
        case .invalidResponse:
            return "Factory usage response changed."
        case .requestFailed(let statusCode):
            return "Factory usage request failed (HTTP \(statusCode)). Try again later."
        }
    }
}

/// The calls the Droid CLI itself makes: `GET /api/billing/limits` (its Usage & Limits screen),
/// `GET /api/organization/managed-settings` (where Droid reads the org's `factoryTier`), and the
/// WorkOS refresh-token grant under Droid's production client ID.
struct FactoryUsageClient: Sendable {
    static let globalAPIBaseURL = "https://api.factory.ai"
    static let euAPIBaseURL = "https://api.eu.factory.ai"
    static let limitsPath = "/api/billing/limits"
    static let managedSettingsPath = "/api/organization/managed-settings"
    static let refreshURL = URL(string: "https://api.workos.com/user_management/authenticate")!
    static let clientID = "client_01HNM792M5G5G1A2THWPXKFMXB"
    static let organizationHeader = "X-Factory-Org-Id"

    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    static func limitsURL(region: String?) -> URL {
        apiURL(limitsPath, region: region)
    }

    static func managedSettingsURL(region: String?) -> URL {
        apiURL(managedSettingsPath, region: region)
    }

    private static func apiURL(_ path: String, region: String?) -> URL {
        let base = region?.lowercased() == "eu" ? euAPIBaseURL : globalAPIBaseURL
        return URL(string: base + path)!
    }

    func fetchLimits(accessToken: String, organizationID: String?, region: String?) async throws -> HTTPResponse {
        try await httpClient.send(HTTPRequest(
            method: "GET",
            url: Self.limitsURL(region: region),
            headers: Self.apiHeaders(accessToken: accessToken, organizationID: organizationID),
            timeout: 15
        ))
    }

    func fetchManagedSettings(accessToken: String, organizationID: String?, region: String?) async throws -> HTTPResponse {
        try await httpClient.send(HTTPRequest(
            method: "GET",
            url: Self.managedSettingsURL(region: region),
            headers: Self.apiHeaders(accessToken: accessToken, organizationID: organizationID),
            timeout: 10
        ))
    }

    private static func apiHeaders(accessToken: String, organizationID: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "OpenUsage"
        ]
        if let organizationID {
            headers[organizationHeader] = organizationID
        }
        return headers
    }

    func refreshToken(_ refreshToken: String) async throws -> HTTPResponse {
        let body =
            "grant_type=refresh_token" +
            "&refresh_token=\(refreshToken.urlFormEncoded)" +
            "&client_id=\(Self.clientID.urlFormEncoded)"
        return try await httpClient.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))
    }

    func decodeRefreshResponse(_ response: HTTPResponse) -> FactoryRefreshResponse? {
        guard let decoded = try? JSONDecoder().decode(FactoryRefreshResponse.self, from: response.body),
              !decoded.accessToken.isEmpty, !decoded.refreshToken.isEmpty
        else {
            return nil
        }
        return decoded
    }
}
