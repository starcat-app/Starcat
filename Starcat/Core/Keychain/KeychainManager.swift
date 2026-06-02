//
//  KeychainManager.swift
//  Starcat
//
//  安全存储门面 —— 自 2026-06-01 起已改为「本地加密文件存储」，不再使用 macOS Keychain。
//
//  为什么不再用 Keychain：
//  - ad-hoc 签名（Xcode dev 期默认）+ App Sandbox 下，系统会反复弹「输入开机密码」授权框。
//
//  现在的存储介质：
//  - 单个加密文件 `credentials.json`，与数据库同目录。
//
//  安全约束：
//  - ⚠️ 使用 CryptoKit (AES-GCM) 进行本地加密。密钥派生自硬件 UUID。
//  - 仍然保留 KeychainManager 命名以兼容现有代码。
//

import Foundation

/// 安全存储错误。
enum KeychainError: Error, LocalizedError {
    case writeFailed(underlying: Error)
    case readFailed(underlying: Error)
    case deleteFailed(underlying: Error)
    case encryptionFailed(underlying: Error)
    case decryptionFailed(underlying: Error)
    case selfCheckMismatch

    var errorDescription: String? {
        switch self {
        case .writeFailed(let error):
            return String(format: String(localized: "keychain.error.writeFailedFormat"), error.localizedDescription)
        case .readFailed(let error):
            return String(format: String(localized: "keychain.error.readFailedFormat"), error.localizedDescription)
        case .deleteFailed(let error):
            return String(format: String(localized: "keychain.error.deleteFailedFormat"), error.localizedDescription)
        case .encryptionFailed(let error):
            return "加密失败: \(error.localizedDescription)"
        case .decryptionFailed(let error):
            return "解密失败: \(error.localizedDescription)"
        case .selfCheckMismatch:
            return String(localized: "keychain.error.selfCheckMismatch")
        }
    }
}

/// 安全存储门面协议。
protocol KeychainManaging: Sendable {
    func storeGithubToken(_ token: String) throws
    func loadGithubToken() throws -> String?
    func deleteGithubToken() throws

    func storeAIKey(_ key: String) throws
    func loadAIKey() throws -> String?
    func deleteAIKey() throws

    func ping() throws
}

/// 默认实现：本地加密文件存储。
final class KeychainManager: KeychainManaging, @unchecked Sendable {

    static let shared = KeychainManager()

    private enum Account {
        static let githubToken = "github_access_token"
        static let aiKey = "ai_api_key"
        static let selfCheck = "self_check_canary"
    }

    private static let selfCheckCanary = "hello-secure-store"
    private static let credentialsFileName = "credentials.json"

    private let lock = NSLock()

    private init() {}

    private static func credentialsFileURL() throws -> URL {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw KeychainError.writeFailed(underlying: CocoaError(.fileNoSuchFile))
        }
        let dir = appSupport.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(Self.credentialsFileName)
    }

    private func loadAllLocked() -> [String: String] {
        guard let url = try? Self.credentialsFileURL(),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return [:]
        }

        // 1. 尝试解密
        var finalData = data
        do {
            finalData = try CryptoManager.shared.decrypt(data)
        } catch {
            // 如果解密失败，尝试作为明文解析（处理 D-16 之前的旧数据）
            AppLog.keychain.info("loadAll: decrypt failed, trying as plain JSON (migration)")
        }

        // 2. 解析 JSON
        do {
            return try JSONDecoder().decode([String: String].self, from: finalData)
        } catch {
            AppLog.keychain.error("loadAll: decode failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func saveAllLocked(_ dict: [String: String]) throws {
        do {
            let url = try Self.credentialsFileURL()
            let plainData = try JSONEncoder().encodeSorted(dict)

            // 1. 加密数据
            let encryptedData = try CryptoManager.shared.encrypt(plainData)

            // 2. 原子写入
            try encryptedData.write(to: url, options: [.atomic])

            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
        } catch {
            if error is KeychainError {
                throw error
            }
            throw KeychainError.writeFailed(underlying: error)
        }
    }

    private func setValue(_ value: String?, forAccount account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var dict = loadAllLocked()
        if let value, !value.isEmpty {
            dict[account] = value
        } else {
            dict.removeValue(forKey: account)
        }
        try saveAllLocked(dict)
    }

    private func value(forAccount account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let v = loadAllLocked()[account]
        return (v?.isEmpty == false) ? v : nil
    }

    func storeGithubToken(_ token: String) throws {
        try setValue(token, forAccount: Account.githubToken)
        AppLog.keychain.info("storeGithubToken: encrypted file write ok")
    }

    func loadGithubToken() throws -> String? {
        let token = value(forAccount: Account.githubToken)
        AppLog.keychain.info("loadGithubToken: \(token == nil ? "miss" : "hit", privacy: .public)")
        return token
    }

    func deleteGithubToken() throws {
        try setValue(nil, forAccount: Account.githubToken)
        AppLog.keychain.info("deleteGithubToken: local file removed")
    }

    func storeAIKey(_ key: String) throws {
        try setValue(key, forAccount: Account.aiKey)
        AppLog.keychain.info("AI key stored securely")
    }

    func loadAIKey() throws -> String? {
        value(forAccount: Account.aiKey)
    }

    func deleteAIKey() throws {
        try setValue(nil, forAccount: Account.aiKey)
        AppLog.keychain.info("AI key removed")
    }

    func ping() throws {
        let canary = Self.selfCheckCanary
        try setValue(canary, forAccount: Account.selfCheck)

        let readBack = value(forAccount: Account.selfCheck)
        guard readBack == canary else {
            AppLog.keychain.error("Secure store self-check mismatch")
            throw KeychainError.selfCheckMismatch
        }

        try? setValue(nil, forAccount: Account.selfCheck)
        AppLog.keychain.info("Secure store self-check ok")
    }
}

// MARK: - JSONEncoder 排序辅助

private extension JSONEncoder {
    /// 输出按 key 排序的 JSON，便于人工查看与 diff 稳定。
    func encodeSorted(_ value: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
}

