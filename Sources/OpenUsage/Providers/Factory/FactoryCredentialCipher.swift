import CryptoKit
import Foundation

/// Droid's credential-file envelope: AES-256-GCM, serialized as `base64(iv):base64(tag):base64(ciphertext)`
/// with a 16-byte IV and 16-byte tag. The 32-byte key lives in the Keychain or `auth.v2.key`.
enum FactoryCredentialCipher {
    static let keyLength = 32
    static let ivLength = 16
    static let tagLength = 16

    static func decrypt(_ envelope: String, key: Data) throws -> String {
        let parts = envelope.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard key.count == keyLength,
              parts.count == 3,
              let iv = Data(base64Encoded: String(parts[0])), iv.count == ivLength,
              let tag = Data(base64Encoded: String(parts[1])), tag.count == tagLength,
              let ciphertext = Data(base64Encoded: String(parts[2]))
        else {
            throw FactoryAuthError.credentialsUnreadable
        }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw FactoryAuthError.credentialsUnreadable
            }
            return text
        } catch {
            throw FactoryAuthError.credentialsUnreadable
        }
    }

    static func encrypt(_ plaintext: String, key: Data, iv: Data? = nil) throws -> String {
        guard key.count == keyLength else { throw FactoryAuthError.credentialsUnreadable }
        let ivData = iv ?? Data((0..<ivLength).map { _ in UInt8.random(in: .min ... .max) })
        let box = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: ivData)
        )
        return [ivData, box.tag, box.ciphertext].map { $0.base64EncodedString() }.joined(separator: ":")
    }

    /// Droid stores the key base64-encoded; anything that isn't exactly 32 bytes is unusable.
    static func decodeKey(_ text: String?) -> Data? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let key = Data(base64Encoded: text), key.count == keyLength
        else {
            return nil
        }
        return key
    }
}
