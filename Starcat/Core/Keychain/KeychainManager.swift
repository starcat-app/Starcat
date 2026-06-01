//
//  KeychainManager.swift
//  Starcat
//
//  安全存储门面 —— ⚠️ 自 2026-06-01 起已改为「纯本地文件存储」，不再使用 macOS Keychain。
//
//  为什么不再用 Keychain：
//  - ad-hoc 签名（Xcode dev 期默认）+ App Sandbox 下，每次构建二进制 codesign hash 都变，
//    历史写入的 Keychain item ACL 与新构建不匹配，系统会反复弹「输入开机密码」授权框，
//    且 token 经常跨构建读不回来（表现为每次启动都要重新登录）。
//  - dong4j 明确要求：token 直接存用户本地文件，彻底摆脱 Keychain 授权弹窗。
//
//  现在的存储介质：
//  - 单个 JSON 文件 `credentials.json`，与数据库同目录：
//    ~/Library/Containers/com.starcat.app/Data/Library/Application Support/com.starcat.app/credentials.json
//  - 文件结构：{ "github_access_token": "...", "ai_api_key": "..." }
//
//  安全约束（重要）：
//  - ⚠️ token / API key 以【明文】存储。仅适用于本机个人使用的开发工具场景。
//  - 缓解措施：文件权限设为 0600（仅当前用户可读写）+ 标记排除 iCloud / Time Machine 备份，
//    降低被其他进程 / 云备份带出去的概率。
//  - 不在日志里打印 token / key 原文；自检 (ping) 用一个固定 canary 字符串。
//
//  线程安全：
//  - 所有读写都过同一把 NSLock，保证 store→load 的强一致（GitHubAPIClient 可能在任意线程读 token）。
//  - 文件写入用 atomically: true（先写临时文件再 rename），避免半写状态。
//

import Foundation

/// 安全存储错误。
///
/// 仅保留语义清晰的错误类型，底层 IO 错误包在 underlying 里，业务层不直接关心。
/// 命名保留 `KeychainError`：调用方与本地化键（keychain.error.*）暂不改动，降低改动面。
enum KeychainError: Error, LocalizedError {
    case writeFailed(underlying: Error)
    case readFailed(underlying: Error)
    case deleteFailed(underlying: Error)
    case selfCheckMismatch

    var errorDescription: String? {
        switch self {
        case .writeFailed(let error):
            return String(format: String(localized: "keychain.error.writeFailedFormat"), error.localizedDescription)
        case .readFailed(let error):
            return String(format: String(localized: "keychain.error.readFailedFormat"), error.localizedDescription)
        case .deleteFailed(let error):
            return String(format: String(localized: "keychain.error.deleteFailedFormat"), error.localizedDescription)
        case .selfCheckMismatch:
            return String(localized: "keychain.error.selfCheckMismatch")
        }
    }
}

/// 安全存储门面协议。
///
/// 协议名保留 `KeychainManaging`：业务层依赖此协议，便于测试中替换为 InMemory 实现。
/// （实现已从 Keychain 切换为本地文件，但协议契约不变，故名字暂不动。）
protocol KeychainManaging: Sendable {
    func storeGithubToken(_ token: String) throws
    func loadGithubToken() throws -> String?
    func deleteGithubToken() throws

    func storeAIKey(_ key: String) throws
    func loadAIKey() throws -> String?
    func deleteAIKey() throws

    /// 启动自检：写入 → 读出 → 删除一个固定值，验证存储可用。
    /// 失败时抛错，由 App 启动流程决定是否继续。
    func ping() throws
}

/// 默认实现：纯本地 JSON 文件存储（不再依赖 KeychainAccess）。
final class KeychainManager: KeychainManaging, @unchecked Sendable {

    // MARK: - 单例

    static let shared = KeychainManager()

    // MARK: - 存储键

    /// JSON 文件中区分不同 secret 用的 key。
    private enum Account {
        static let githubToken = "github_access_token"
        static let aiKey = "ai_api_key"
        static let selfCheck = "self_check_canary"
    }

    /// 自检用的固定 canary 值。任何明文都行，重要的是写入后能完整读回。
    private static let selfCheckCanary = "hello-local-store"

    /// 凭据文件名（与数据库同目录）。
    private static let credentialsFileName = "credentials.json"

    // MARK: - 并发控制

    /// 读写共用一把锁，保证 store→load 强一致；本类调用频率极低，锁开销可忽略。
    private let lock = NSLock()

    private init() {}

    // MARK: - 文件位置

    /// 解析凭据文件 URL，并保证父目录存在。
    ///
    /// 与 `DatabaseManager.databaseFileURL()` 落在同一目录（Application Support/<bundleId>/），
    /// 方便在 Finder 里一处查看 App 的全部本地数据。
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

    // MARK: - 底层读写（均需持锁调用）

    /// 读取整张凭据表；文件不存在或解析失败时返回空字典（视为"还没存过"）。
    private func loadAllLocked() -> [String: String] {
        guard let url = try? Self.credentialsFileURL(),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // 文件存在但解析失败：当作空表，避免一个坏文件让用户永远登录不进去。
            AppLog.keychain.error("loadAll: decode failed, treating as empty: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// 原子写回整张凭据表，并收紧文件权限 + 排除备份。
    private func saveAllLocked(_ dict: [String: String]) throws {
        do {
            let url = try Self.credentialsFileURL()
            // sortedKeys 仅为便于人工查看 diff，无功能影响。
            let data = try JSONEncoder().encodeSorted(dict)
            // atomically: 先写临时文件再 rename，杜绝半写状态。
            try data.write(to: url, options: [.atomic])

            // 权限收紧到仅 owner 读写（0600），降低同机其他用户/进程读取概率。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

            // 排除 iCloud / Time Machine 备份，避免明文 token 被带出本机。
            // setResourceValues 需要 var；失败不致命，仅降级安全性。
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
        } catch {
            throw KeychainError.writeFailed(underlying: error)
        }
    }

    /// 设置（或在 value 为 nil 时删除）某个键，整表回写。
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

    /// 读取某个键。
    private func value(forAccount account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let v = loadAllLocked()[account]
        return (v?.isEmpty == false) ? v : nil
    }

    // MARK: - GitHub Token

    func storeGithubToken(_ token: String) throws {
        try setValue(token, forAccount: Account.githubToken)
        AppLog.keychain.info("storeGithubToken: local file write ok")
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

    // MARK: - AI API Key

    func storeAIKey(_ key: String) throws {
        try setValue(key, forAccount: Account.aiKey)
        AppLog.keychain.info("AI key stored")
    }

    func loadAIKey() throws -> String? {
        value(forAccount: Account.aiKey)
    }

    func deleteAIKey() throws {
        try setValue(nil, forAccount: Account.aiKey)
        AppLog.keychain.info("AI key removed")
    }

    // MARK: - 自检

    func ping() throws {
        let canary = Self.selfCheckCanary
        try setValue(canary, forAccount: Account.selfCheck)

        let readBack = value(forAccount: Account.selfCheck)
        guard readBack == canary else {
            AppLog.keychain.error("Self-check mismatch: expected=\(canary, privacy: .public), got=\(readBack ?? "<nil>", privacy: .public)")
            throw KeychainError.selfCheckMismatch
        }

        // 自检完清除，避免污染。
        try? setValue(nil, forAccount: Account.selfCheck)
        AppLog.keychain.info("Local store self-check ok")
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
