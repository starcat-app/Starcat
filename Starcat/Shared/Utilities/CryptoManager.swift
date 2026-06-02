//
//  CryptoManager.swift
//  Starcat
//
//  加密工具类 —— 使用 CryptoKit 对本地凭据进行 AES-GCM 加密。
//
//  设计思路：
//  - 密钥派生：从硬件 UUID (IOPlatformUUID) 结合固定盐值通过 HKDF 派生 SymmetricKey。
//  - 加密算法：AES-GCM (Authenticated Encryption)，防止数据被篡改。
//  - 平台约束：仅限 macOS。
//

import Foundation
import CryptoKit
import IOKit

/// 加密管理类，负责本地敏感数据的加解密。
final class CryptoManager: Sendable {

    static let shared = CryptoManager()

    /// 用于密钥派生的固定盐值。
    private let salt = "Starcat-Crypto-Salt-2026".data(using: .utf8)!

    private init() {}

    // MARK: - 核心接口

    /// 加密数据。
    func encrypt(_ data: Data) throws -> Data {
        let key = try deriveKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        return sealedBox.combined!
    }

    /// 解密数据。
    func decrypt(_ combinedData: Data) throws -> Data {
        let key = try deriveKey()
        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - 私有方法

    /// 从硬件 UUID 派生对称密钥。
    private func deriveKey() throws -> SymmetricKey {
        guard let uuid = getHardwareUUID(),
              let uuidData = uuid.data(using: .utf8) else {
            // 如果拿不到 UUID，退化为使用 bundleId 作为后备（安全性较低但保证可用）
            let fallbackData = AppConstants.bundleIdentifier.data(using: .utf8)!
            return deriveKey(from: fallbackData)
        }
        return deriveKey(from: uuidData)
    }

    private func deriveKey(from material: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: salt,
            outputByteCount: 32
        )
    }

    /// 获取 macOS 硬件 UUID (IOPlatformUUID)。
    private func getHardwareUUID() -> String? {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, matching)
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        guard let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }

        return (uuid.takeRetainedValue() as? String)
    }
}
