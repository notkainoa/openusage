import XCTest
@testable import OpenUsage

final class FactoryCredentialTests: XCTestCase {
    // MARK: - Cipher

    /// Produced by Node's `crypto.createCipheriv("aes-256-gcm", key, iv)` with Droid's
    /// `iv:tag:ciphertext` serialization — the exact envelope the CLI writes.
    func testDecryptsDroidEnvelopeProducedByNode() throws {
        let key = try XCTUnwrap(FactoryCredentialCipher.decodeKey("BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="))
        let envelope = "AwMDAwMDAwMDAwMDAwMDAw==:4kwg8PYV+gMRb8ljNWZTjQ==:el0kIxn7lu64YseB8oT1fD5NGE5jiH8dyYzK4VkNOBc8lrsi5my2+g=="

        let plaintext = try FactoryCredentialCipher.decrypt(envelope, key: key)

        XCTAssertEqual(plaintext, #"{"access_token":"a","refresh_token":"r"}"#)
    }

    func testEncryptMatchesDroidSerializationAndRoundTrips() throws {
        let key = FactoryFixtures.key
        let iv = Data(repeating: 3, count: 16)

        let envelope = try FactoryCredentialCipher.encrypt(#"{"access_token":"a","refresh_token":"r"}"#, key: Data(repeating: 7, count: 32), iv: iv)
        XCTAssertEqual(envelope, "AwMDAwMDAwMDAwMDAwMDAw==:4kwg8PYV+gMRb8ljNWZTjQ==:el0kIxn7lu64YseB8oT1fD5NGE5jiH8dyYzK4VkNOBc8lrsi5my2+g==")

        let random = try FactoryCredentialCipher.encrypt("hello", key: key)
        XCTAssertEqual(try FactoryCredentialCipher.decrypt(random, key: key), "hello")
    }

    func testDecryptRejectsWrongKeyAndMalformedEnvelope() {
        let envelope = try! FactoryCredentialCipher.encrypt("hello", key: FactoryFixtures.key)
        XCTAssertThrowsError(try FactoryCredentialCipher.decrypt(envelope, key: Data(repeating: 1, count: 32))) {
            XCTAssertEqual($0 as? FactoryAuthError, .credentialsUnreadable)
        }
        XCTAssertThrowsError(try FactoryCredentialCipher.decrypt("not-an-envelope", key: FactoryFixtures.key))
        XCTAssertNil(FactoryCredentialCipher.decodeKey("c2hvcnQ="))
    }

    // MARK: - Auth store

    func testLoadsLoginKeychainSourceWithOrgAndRegion() throws {
        let files = FakeFiles([
            FactoryAuthStore.loginKeychainCredentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(
                access: "access", refresh: "refresh", organizationID: "org_1", whoami: ["region": "eu"]
            ))
        ])
        let store = FactoryFixtures.store(files: files)

        let state = try XCTUnwrap(try store.load())

        XCTAssertEqual(state.source, .loginKeychain)
        XCTAssertEqual(state.credentials, FactoryCredentials(
            accessToken: "access", refreshToken: "refresh", organizationID: "org_1", region: "eu"
        ))
    }

    func testFallsBackToKeyFileWhenKeychainKeyIsMissing() throws {
        let files = FakeFiles([
            FactoryAuthStore.loginKeychainCredentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: "stale")),
            FactoryAuthStore.keyFileCredentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: "from-file")),
            FactoryAuthStore.keyFilePath: FactoryFixtures.key.base64EncodedString()
        ])
        let store = FactoryFixtures.store(files: files, keychain: ServiceKeychain())

        let state = try XCTUnwrap(try store.load())

        XCTAssertEqual(state.source, .keyFile)
        XCTAssertEqual(state.credentials.accessToken, "from-file")
    }

    func testReportsUnreadableLoginInsteadOfLoggedOut() {
        let files = FakeFiles([
            FactoryAuthStore.loginKeychainCredentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: "a"))
        ])
        let store = FactoryFixtures.store(files: files, keychain: ServiceKeychain())

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? FactoryAuthError, .credentialsUnreadable)
        }
    }

    func testNoFilesMeansNotLoggedIn() throws {
        let store = FactoryFixtures.store(files: FakeFiles())
        XCTAssertNil(try store.load())
        XCTAssertFalse(store.hasCredentialMaterial())
    }

    func testCredentialProbeMirrorsBothSources() {
        let keychainFile = FakeFiles([FactoryAuthStore.loginKeychainCredentialsPath: "x"])
        XCTAssertTrue(FactoryFixtures.store(files: keychainFile).hasCredentialMaterial())
        XCTAssertFalse(FactoryFixtures.store(files: keychainFile, keychain: ServiceKeychain()).hasCredentialMaterial())

        let keyFilePair = FakeFiles([FactoryAuthStore.keyFileCredentialsPath: "x", FactoryAuthStore.keyFilePath: "k"])
        XCTAssertTrue(FactoryFixtures.store(files: keyFilePair, keychain: ServiceKeychain()).hasCredentialMaterial())

        let lonelyFile = FakeFiles([FactoryAuthStore.keyFileCredentialsPath: "x"])
        XCTAssertFalse(FactoryFixtures.store(files: lonelyFile, keychain: ServiceKeychain()).hasCredentialMaterial())
    }

    func testSavePreservesOtherFieldsAndSkipsWhenDroidRewroteTheFile() throws {
        let path = FactoryAuthStore.loginKeychainCredentialsPath
        let files = FakeFiles([path: FactoryFixtures.envelope(FactoryFixtures.credentials(
            access: "old", refresh: "old-refresh", organizationID: "org_1", whoami: ["region": "global", "userId": "u1"]
        ))])
        let store = FactoryFixtures.store(files: files)
        let state = try XCTUnwrap(try store.load())
        var rotated = state.credentials
        rotated.accessToken = "new"
        rotated.refreshToken = "new-refresh"

        let saved = try XCTUnwrap(try store.save(rotated, over: state))

        let object = try FactoryFixtures.decryptedObject(files.files[path])
        XCTAssertEqual(object["access_token"] as? String, "new")
        XCTAssertEqual(object["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(object["active_organization_id"] as? String, "org_1")
        XCTAssertEqual((object["whoami"] as? [String: Any])?["userId"] as? String, "u1")
        XCTAssertEqual(saved.envelope, files.files[path])

        // `state` is now stale: Droid's copy (here, our own save) wins and nothing is written.
        let before = files.files[path]
        XCTAssertNil(try store.save(rotated, over: state))
        XCTAssertEqual(files.files[path], before)
    }

    func testExpiryIsStrictlyPastExp() {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = FactoryAuthStore(files: FakeFiles(), keychain: ServiceKeychain(), now: { now })
        XCTAssertFalse(store.isExpired(makeCursorJWT(exp: 1_001)))
        XCTAssertTrue(store.isExpired(makeCursorJWT(exp: 1_000)))
        XCTAssertFalse(store.isExpired("opaque-token"))
    }

    func testLockedKeychainIsACredentialAccessErrorNotALogout() {
        let files = FakeFiles([
            FactoryAuthStore.loginKeychainCredentialsPath: FactoryFixtures.envelope(FactoryFixtures.credentials(access: "a"))
        ])
        let store = FactoryFixtures.store(files: files, keychain: ThrowingKeychain())

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? FactoryAuthError, .keychainUnavailable)
            XCTAssertEqual(($0 as? FactoryAuthError)?.errorCategory, .credentialAccess)
        }
    }

    func testLoginWithoutTokensIsUnreadable() {
        let files = FakeFiles([
            FactoryAuthStore.loginKeychainCredentialsPath: FactoryFixtures.envelope(["access_token": "a"])
        ])

        XCTAssertThrowsError(try FactoryFixtures.store(files: files).load()) {
            XCTAssertEqual($0 as? FactoryAuthError, .credentialsUnreadable)
        }
    }
}

private struct ThrowingKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { throw POSIXError(.EACCES) }
    func writeGenericPassword(service: String, value: String) throws { throw POSIXError(.EACCES) }
}

// MARK: - Shared fixtures

enum FactoryFixtures {
    static let key = Data((0..<32).map { UInt8($0) })

    static func credentials(
        access: String,
        refresh: String = "refresh",
        organizationID: String? = nil,
        whoami: [String: Any]? = nil
    ) -> [String: Any] {
        var object: [String: Any] = ["access_token": access, "refresh_token": refresh]
        if let organizationID { object["active_organization_id"] = organizationID }
        if let whoami { object["whoami"] = whoami }
        return object
    }

    static func envelope(_ object: [String: Any], key: Data = key) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! FactoryCredentialCipher.encrypt(String(decoding: data, as: UTF8.self), key: key)
    }

    static func decryptedObject(_ envelope: String?) throws -> [String: Any] {
        let plaintext = try FactoryCredentialCipher.decrypt(try XCTUnwrap(envelope), key: key)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any])
    }

    static func keychain() -> ServiceKeychain {
        ServiceKeychain(values: [FactoryAuthStore.keychainService: key.base64EncodedString()])
    }

    static func store(
        files: TextFileAccessing,
        keychain: KeychainAccessing = keychain(),
        now: Date = Date(timeIntervalSince1970: 1_790_000_000)
    ) -> FactoryAuthStore {
        FactoryAuthStore(files: files, keychain: keychain, now: { now })
    }
}

/// Reads through to `FakeFiles` but refuses every write, for the "save failed" path.
final class ReadOnlyFiles: TextFileAccessing, @unchecked Sendable {
    let base: FakeFiles

    init(_ base: FakeFiles) {
        self.base = base
    }

    func exists(_ path: String) -> Bool { base.exists(path) }
    func readText(_ path: String) throws -> String { try base.readText(path) }
    func writeText(_ path: String, _ text: String) throws { throw POSIXError(.EROFS) }
    func remove(_ path: String) throws { throw POSIXError(.EROFS) }
}
