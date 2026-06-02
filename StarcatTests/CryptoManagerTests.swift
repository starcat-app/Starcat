//
//  CryptoManagerTests.swift
//  StarcatTests
//

import Testing
import Foundation
@testable import Starcat

@Suite("CryptoManager")
struct CryptoManagerTests {

    @Test("加解密对称性")
    func testEncryptionRoundtrip() throws {
        let sut = CryptoManager.shared
        let originalText = "Hello, Starcat Crypto!"
        let originalData = originalText.data(using: .utf8)!

        // 1. 加密
        let encryptedData = try sut.encrypt(originalData)
        #expect(encryptedData != originalData, "加密后的数据应与原数据不同")

        // 2. 解密
        let decryptedData = try sut.decrypt(encryptedData)
        let decryptedText = String(data: decryptedData, encoding: .utf8)

        #expect(decryptedText == originalText, "解密后的文本应与原文本一致")
    }

    @Test("不同数据加密结果不同")
    func testDifferentData() throws {
        let sut = CryptoManager.shared
        let data1 = "Message 1".data(using: .utf8)!
        let data2 = "Message 2".data(using: .utf8)!

        let enc1 = try sut.encrypt(data1)
        let enc2 = try sut.encrypt(data2)

        #expect(enc1 != enc2)
    }

    @Test("解密非法数据应抛错")
    func testDecryptInvalidData() {
        let sut = CryptoManager.shared
        let invalidData = "Not encrypted data".data(using: .utf8)!

        #expect(throws: Error.self) {
            try sut.decrypt(invalidData)
        }
    }
}
