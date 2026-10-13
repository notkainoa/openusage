import Foundation

struct FactoryCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var organizationID: String?
    var region: String?
}

enum FactoryCredentialSource: String, Sendable {
    /// `auth.v2.loginkeychain`, keyed by the `Factory CLI` Keychain item — Droid's macOS default.
    case loginKeychain
    /// `auth.v2.file`, keyed by `auth.v2.key` — Droid's fallback when the Keychain is unavailable.
    case keyFile

    var credentialsPath: String {
        switch self {
        case .loginKeychain: FactoryAuthStore.loginKeychainCredentialsPath
        case .keyFile: FactoryAuthStore.keyFileCredentialsPath
        }
    }
}

struct FactoryAuthState: Sendable {
    var source: FactoryCredentialSource
    var credentials: FactoryCredentials
    /// The exact file text these credentials were decrypted from, so a save can detect that Droid
    /// rewrote the login in the meantime.
    var envelope: String
    var key: Data
}

enum FactoryAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case keychainUnavailable
    case credentialsUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Factory not logged in. Run `droid` and sign in."
        case .sessionExpired:
            return "Factory session expired. Run `droid` and sign in again."
        case .keychainUnavailable:
            return "Couldn't read Droid's login key from the Keychain. Unlock your Keychain and try again."
        case .credentialsUnreadable:
            return "Couldn't read Droid's saved login. Run `droid` and sign in again."
        }
    }
}

/// Reads (and, after a token rotation, rewrites) the login the Droid CLI keeps in `~/.factory`.
/// Droid owns the format: an AES-256-GCM envelope (see `FactoryCredentialCipher`) around
/// `{access_token, refresh_token, active_organization_id?, whoami?, region?}`.
struct FactoryAuthStore: Sendable {
    static let loginKeychainCredentialsPath = "~/.factory/auth.v2.loginkeychain"
    static let keyFileCredentialsPath = "~/.factory/auth.v2.file"
    static let keyFilePath = "~/.factory/auth.v2.key"
    static let keychainService = "Factory CLI"
    static let keychainAccount = "auth-encryption-key-security-cli"

    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.keychain = keychain
        self.now = now
    }

    /// Prompt-free evidence for first-run detection: the same two sources `load()` reads, checked by
    /// presence only. A Keychain probe that can't answer counts as present — the file alone is
    /// strong evidence, and the real refresh still decrypts and validates.
    func hasCredentialMaterial() -> Bool {
        if files.exists(Self.loginKeychainCredentialsPath),
           keychain.genericPasswordExists(service: Self.keychainService) != false {
            return true
        }
        return files.exists(Self.keyFileCredentialsPath) && files.exists(Self.keyFilePath)
    }

    /// Droid's read order: the Keychain-keyed file first, then the key-file pair. A source that
    /// exists but can't be decrypted falls through to the next one, like the CLI; if neither works the
    /// first failure is reported rather than "not logged in".
    func load() throws -> FactoryAuthState? {
        var firstFailure: Error?
        for source in [FactoryCredentialSource.loginKeychain, .keyFile] {
            do {
                if let state = try load(source) { return state }
            } catch {
                AppLog.warn(LogTag.auth("factory"), "could not read Droid credentials (source=\(source.rawValue)): \(error.localizedDescription)")
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
        return nil
    }

    /// Write rotated tokens back into the file `state` came from. Returns `nil` without writing when
    /// the file no longer matches `state.envelope` — Droid rotated or cleared the login first, and its
    /// copy wins. Every other field in the payload is preserved. Like Claude's save, this is a
    /// best-effort compare-then-write: there is no atomic compare-and-swap on the file.
    func save(_ credentials: FactoryCredentials, over state: FactoryAuthState) throws -> FactoryAuthState? {
        let path = state.source.credentialsPath
        guard let current = try readCredentialFile(path), current == state.envelope else { return nil }
        let plaintext = try FactoryCredentialCipher.decrypt(current, key: state.key)
        guard var object = Self.jsonObject(plaintext) else { throw FactoryAuthError.credentialsUnreadable }
        object["access_token"] = credentials.accessToken
        object["refresh_token"] = credentials.refreshToken
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        let envelope = try FactoryCredentialCipher.encrypt(String(decoding: data, as: UTF8.self), key: state.key)
        try files.writeText(path, envelope)
        AppLog.debug(LogTag.auth("factory"), "persisted rotated credentials (source=\(state.source.rawValue))")
        return FactoryAuthState(source: state.source, credentials: credentials, envelope: envelope, key: state.key)
    }

    /// Strictly past `exp`. Droid renews 60s early, so while it's running it rotates first and
    /// OpenUsage just reads the result instead of racing it for the same refresh token.
    func isExpired(_ accessToken: String) -> Bool {
        guard let exp = ProviderParse.jwtPayload(accessToken)?["exp"].flatMap(ProviderParse.number) else {
            return false
        }
        return now() >= Date(timeIntervalSince1970: exp)
    }

    // MARK: - Private

    private func load(_ source: FactoryCredentialSource) throws -> FactoryAuthState? {
        guard let envelope = try readCredentialFile(source.credentialsPath) else { return nil }
        let key = try encryptionKey(for: source)
        let plaintext = try FactoryCredentialCipher.decrypt(envelope, key: key)
        guard let credentials = Self.parseCredentials(plaintext) else {
            throw FactoryAuthError.credentialsUnreadable
        }
        return FactoryAuthState(source: source, credentials: credentials, envelope: envelope, key: key)
    }

    private func encryptionKey(for source: FactoryCredentialSource) throws -> Data {
        let raw: String?
        switch source {
        case .loginKeychain:
            do {
                raw = try keychain.readGenericPassword(service: Self.keychainService, account: Self.keychainAccount)
            } catch {
                throw FactoryAuthError.keychainUnavailable
            }
        case .keyFile:
            raw = try readCredentialFile(Self.keyFilePath)
        }
        guard let key = FactoryCredentialCipher.decodeKey(raw) else {
            throw FactoryAuthError.credentialsUnreadable
        }
        return key
    }

    private func readCredentialFile(_ path: String) throws -> String? {
        do {
            return try files.readTextIfPresent(path)
        } catch {
            throw FactoryAuthError.credentialsUnreadable
        }
    }

    static func parseCredentials(_ plaintext: String) -> FactoryCredentials? {
        guard let object = jsonObject(plaintext),
              let accessToken = trimmed(object["access_token"]),
              let refreshToken = trimmed(object["refresh_token"])
        else {
            return nil
        }
        let whoami = object["whoami"] as? [String: Any]
        return FactoryCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            organizationID: trimmed(object["active_organization_id"]),
            region: trimmed(whoami?["region"]) ?? trimmed(object["region"])
        )
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func trimmed(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
