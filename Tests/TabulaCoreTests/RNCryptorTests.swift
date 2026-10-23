import Foundation
import Testing
@testable import TabulaCore

struct RNCryptorTests {
    let salt1: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    let salt2: [UInt8] = [2, 3, 4, 5, 6, 7, 8, 9]
    let iv: [UInt8] = Array(3...18)

    @Test func roundTrips() throws {
        let plain = Data(#"[{"ConnectionName":"x"}]"#.utf8)
        let encrypted = try RNCryptor.encrypt(plain, password: "secret", encryptionSalt: salt1, hmacSalt: salt2, iv: iv)
        #expect(RNCryptor.isEncrypted(encrypted))
        #expect(try RNCryptor.decrypt(encrypted, password: "secret") == plain)
    }

    @Test func wrongPasswordIsDetectedByHMAC() throws {
        let encrypted = try RNCryptor.encrypt(Data("x".utf8), password: "right", encryptionSalt: salt1, hmacSalt: salt2, iv: iv)
        #expect(throws: RNCryptor.Failure.wrongPassword) { try RNCryptor.decrypt(encrypted, password: "wrong") }
    }

    /// Official RNCryptor v3 password test vector ("One byte").
    @Test func matchesSpecVector() throws {
        let ciphertext = Data(hex: """
            03010001 02030405 06070102 03040506 07080203 04050607 08090a0b 0c0d0e0f 0001a1f8 730e0bf4
            80eb7b70 f690abf2 1e029514 164ad3c4 74a51b30 c7eaa1ca 545b7de3 de5b010a cbad0a9a 13857df6 96a8
            """)
        #expect(try RNCryptor.decrypt(ciphertext, password: "thepassword") == Data([0x01]))
    }
}

extension Data {
    init(hex: String) {
        let digits = hex.filter(\.isHexDigit)
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
