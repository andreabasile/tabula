import CommonCrypto
import Foundation

/// RNCryptor v3 with a password, the format of TablePlus's encrypted connection exports:
/// version(1) options(1) encSalt(8) hmacSalt(8) iv(16) ciphertext hmac(32);
/// keys from PBKDF2-SHA1 (10 000 rounds), AES-256-CBC, HMAC-SHA256 over everything before it.
public enum RNCryptor {
    public enum Failure: Error, Equatable, LocalizedError {
        case unknownFormat
        case wrongPassword
        case decryptionFailed

        public var errorDescription: String? {
            switch self {
            case .unknownFormat: "Il file non è un export cifrato di TablePlus."
            case .wrongPassword: "Password errata."
            case .decryptionFailed: "Impossibile decifrare il file."
            }
        }
    }

    private static let headerLength = 34
    private static let hmacLength = 32
    private static let rounds: UInt32 = 10_000

    public static func isEncrypted(_ data: Data) -> Bool {
        data.count > headerLength + hmacLength && data[data.startIndex] == 3 && data[data.startIndex + 1] == 1
    }

    public static func decrypt(_ data: Data, password: String) throws -> Data {
        guard isEncrypted(data) else { throw Failure.unknownFormat }
        let bytes = [UInt8](data)
        let encryptionSalt = Array(bytes[2..<10])
        let hmacSalt = Array(bytes[10..<18])
        let iv = Array(bytes[18..<34])
        let signed = Array(bytes[0..<(bytes.count - hmacLength)])
        let ciphertext = Array(bytes[headerLength..<(bytes.count - hmacLength)])
        let expectedHMAC = Array(bytes[(bytes.count - hmacLength)...])

        let hmacKey = key(password: password, salt: hmacSalt)
        guard constantTimeEquals(hmac(signed, key: hmacKey), expectedHMAC) else { throw Failure.wrongPassword }
        return try aes(CCOperation(kCCDecrypt), ciphertext, key: key(password: password, salt: encryptionSalt), iv: iv)
    }

    /// Used by tests and by nothing else: Tabula never writes TablePlus files.
    static func encrypt(_ plaintext: Data, password: String, encryptionSalt: [UInt8], hmacSalt: [UInt8], iv: [UInt8]) throws -> Data {
        let ciphertext = try aes(CCOperation(kCCEncrypt), [UInt8](plaintext), key: key(password: password, salt: encryptionSalt), iv: iv)
        let message = [3, 1] + encryptionSalt + hmacSalt + iv + [UInt8](ciphertext)
        return Data(message + hmac(message, key: key(password: password, salt: hmacSalt)))
    }

    private static func key(password: String, salt: [UInt8]) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES256)
        let passwordBytes = Array(password.utf8).map { CChar(bitPattern: $0) }
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count,
            salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
            &derived, derived.count
        )
        return derived
    }

    private static func hmac(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, message, message.count, &digest)
        return digest
    }

    private static func aes(_ operation: CCOperation, _ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> Data {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, input, input.count, &output, output.count, &written
        )
        guard status == kCCSuccess else { throw Failure.decryptionFailed }
        return Data(output.prefix(written))
    }

    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
