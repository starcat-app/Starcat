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
            return String(format: String.l10n("keychain.error.writeFailedFormat"), error.localizedDescription)
        case .readFailed(let error):
            return String(format: String.l10n("keychain.error.readFailedFormat"), error.localizedDescription)
        case .deleteFailed(let error):
            return String(format: String.l10n("keychain.error.deleteFailedFormat"), error.localizedDescription)
        case .encryptionFailed(let error):
            return String(format: String.l10n("keychain.error.encryptionFailedFormat"), error.localizedDescription)
        case .decryptionFailed(let error):
            return String(format: String.l10n("keychain.error.decryptionFailedFormat"), error.localizedDescription)
        case .selfCheckMismatch:
            return String.l10n("keychain.error.selfCheckMismatch")
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
    func storeAIKey(_ key: String, forProvider providerID: String) throws
    func loadAIKey(forProvider providerID: String) throws -> String?
    func deleteAIKey(forProvider providerID: String) throws

    // R-01 v1.2 新增（2026-06-10）：自建后端服务 API Key（trending / weekly / sharing / wiki）。
    // BYOK 模式下用户在「设置 → 服务」Tab 填的 Key 走加密本地文件持久化，
    // 与 GitHub Token / AI Key 同等安全级别（AES-GCM）。
    //
    // serviceID 参数：用 `ThirdPartyService.rawValue`（"trending" / "weekly" / "sharing" / "wiki"），
    // 调用方负责传字符串 ID（避免 KeychainManaging 反向依赖业务枚举类型）。
    func storeServiceAPIKey(_ key: String, forService serviceID: String) throws
    func loadServiceAPIKey(forService serviceID: String) throws -> String?
    func deleteServiceAPIKey(forService serviceID: String) throws

    /// 清空 Starcat 本机加密凭据文件中的全部条目。
    ///
    /// 只用于“清空所有数据 / 本地恢复出厂”这类明确的 destructive 操作。
    /// 不要在普通登出里调用：登出只删 GitHub token，AI Key / 服务 Key 等配置
    /// 应继续保留；恢复出厂才需要把这些本机配置一并抹掉。
    func deleteAllCredentials() throws

    func ping() throws
}

/// 默认实现：本地加密文件存储。
final class KeychainManager: KeychainManaging, @unchecked Sendable {

    static let shared = KeychainManager()

    private enum Account {
        static let githubToken = "github_access_token"
        static let aiKey = "ai_api_key"
        static let selfCheck = "self_check_canary"

        static func aiKey(providerID: String) -> String {
            "ai_api_key::\(providerID)"
        }

        /// R-01 v1.2：自建后端服务 API Key 命名空间（与 aiKey 解耦，避免 ID 冲突）。
        ///
        /// 形如 `service_api_key::trending` / `service_api_key::weekly` / `service_api_key::sharing` /
        /// `service_api_key::wiki`。
        static func serviceAPIKey(serviceID: String) -> String {
            "service_api_key::\(serviceID)"
        }
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

    func storeAIKey(_ key: String, forProvider providerID: String) throws {
        try setValue(key, forAccount: Account.aiKey(providerID: providerID))
        AppLog.keychain.info("AI provider key stored securely")
    }

    func loadAIKey(forProvider providerID: String) throws -> String? {
        // 迁移兼容：如果新 profile 维度还没有 Key，回退读取旧版全局 AI Key。
        value(forAccount: Account.aiKey(providerID: providerID)) ?? value(forAccount: Account.aiKey)
    }

    func deleteAIKey(forProvider providerID: String) throws {
        try setValue(nil, forAccount: Account.aiKey(providerID: providerID))
        AppLog.keychain.info("AI provider key removed")
    }

    // MARK: - R-01 自建后端服务 API Key（trending / weekly / sharing / wiki）

    func storeServiceAPIKey(_ key: String, forService serviceID: String) throws {
        try setValue(key, forAccount: Account.serviceAPIKey(serviceID: serviceID))
        AppLog.keychain.info("Service API key stored: \(serviceID, privacy: .public)")
    }

    func loadServiceAPIKey(forService serviceID: String) throws -> String? {
        value(forAccount: Account.serviceAPIKey(serviceID: serviceID))
    }

    func deleteServiceAPIKey(forService serviceID: String) throws {
        try setValue(nil, forAccount: Account.serviceAPIKey(serviceID: serviceID))
        AppLog.keychain.info("Service API key removed: \(serviceID, privacy: .public)")
    }

    func deleteAllCredentials() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = try Self.credentialsFileURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            AppLog.keychain.info("All local credentials removed")
        } catch {
            if error is KeychainError {
                throw error
            }
            throw KeychainError.deleteFailed(underlying: error)
        }
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
