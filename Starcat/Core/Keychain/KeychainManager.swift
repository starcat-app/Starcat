//
//  KeychainManager.swift
//  Starcat
//
//  基于 KeychainAccess 的安全存储封装。
//
//  存储内容（按 docs/详细设计/06-核心模块设计.md）：
//  - GitHub OAuth access token
//  - 用户自定义 AI provider API key（BYOK，P1+）
//
//  关键约束：
//  - 所有项目放在同一个 service (`com.starcat.app`)，按 account 区分
//  - kSecAttrAccessible = .afterFirstUnlock：解锁后即可读，重启后无需再次解锁
//    用 .whenUnlocked 会更严，但后台同步任务会取不到 token；按需后续可调
//  - 不在日志里打印 token / key 原文；自检 (ping) 用一个固定常量字符串
//
//  线程安全：KeychainAccess 自身是线程安全的，本封装无额外锁
//

import Foundation
import KeychainAccess

/// Keychain 错误。
///
/// 仅保留语义清晰的错误类型，具体底层 OSStatus 由 KeychainAccess 抛出，业务层不直接关心。
enum KeychainError: Error, LocalizedError {
    case writeFailed(underlying: Error)
    case readFailed(underlying: Error)
    case deleteFailed(underlying: Error)
    case selfCheckMismatch

    var errorDescription: String? {
        switch self {
        case .writeFailed(let error):
            return "Keychain 写入失败：\(error.localizedDescription)"
        case .readFailed(let error):
            return "Keychain 读取失败：\(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Keychain 删除失败：\(error.localizedDescription)"
        case .selfCheckMismatch:
            return "Keychain 自检失败：写入与读出值不一致"
        }
    }
}

/// Keychain 操作门面。
///
/// 单例：Keychain 是设备级共享资源，App 内只需要一份 service 句柄。
/// 协议化：业务层通过 `KeychainManaging` 协议依赖，便于测试中替换为 InMemory 实现。
protocol KeychainManaging: Sendable {
    func storeGithubToken(_ token: String) throws
    func loadGithubToken() throws -> String?
    func deleteGithubToken() throws

    func storeAIKey(_ key: String) throws
    func loadAIKey() throws -> String?
    func deleteAIKey() throws

    /// 启动自检：写入 → 读出 → 删除一个固定值，验证 Keychain 可用。
    /// 失败时抛错，由 App 启动流程决定是否继续。
    func ping() throws
}

/// 默认实现，依赖 KeychainAccess。
final class KeychainManager: KeychainManaging {

    // MARK: - 单例

    static let shared = KeychainManager()

    // MARK: - 内部账户名

    /// Keychain 中区分不同 secret 用的 account 字段。
    private enum Account {
        static let githubToken = "github_access_token"
        static let aiKey = "ai_api_key"
        static let selfCheck = "self_check_canary"
    }

    /// 自检用的固定 canary 值。
    /// 任何明文都行，重要的是写入后能完整读回。
    private static let selfCheckCanary = "hello-keychain"

    // MARK: - 底层 Keychain

    private let keychain: Keychain

    private init() {
        // service = bundle id，所有项目同 service 不同 account
        self.keychain = Keychain(service: AppConstants.bundleIdentifier)
            .accessibility(.afterFirstUnlock)
    }

    // MARK: - GitHub Token

    func storeGithubToken(_ token: String) throws {
        do {
            try keychain.set(token, key: Account.githubToken)
            AppLog.keychain.info("GitHub token stored")
        } catch {
            AppLog.keychain.error("Failed to store GitHub token: \(error.localizedDescription, privacy: .public)")
            throw KeychainError.writeFailed(underlying: error)
        }
    }

    func loadGithubToken() throws -> String? {
        do {
            return try keychain.getString(Account.githubToken)
        } catch {
            throw KeychainError.readFailed(underlying: error)
        }
    }

    func deleteGithubToken() throws {
        do {
            try keychain.remove(Account.githubToken)
            AppLog.keychain.info("GitHub token removed")
        } catch {
            throw KeychainError.deleteFailed(underlying: error)
        }
    }

    // MARK: - AI API Key

    func storeAIKey(_ key: String) throws {
        do {
            try keychain.set(key, key: Account.aiKey)
            AppLog.keychain.info("AI key stored")
        } catch {
            throw KeychainError.writeFailed(underlying: error)
        }
    }

    func loadAIKey() throws -> String? {
        do {
            return try keychain.getString(Account.aiKey)
        } catch {
            throw KeychainError.readFailed(underlying: error)
        }
    }

    func deleteAIKey() throws {
        do {
            try keychain.remove(Account.aiKey)
            AppLog.keychain.info("AI key removed")
        } catch {
            throw KeychainError.deleteFailed(underlying: error)
        }
    }

    // MARK: - 自检

    func ping() throws {
        let canary = Self.selfCheckCanary
        do {
            try keychain.set(canary, key: Account.selfCheck)
        } catch {
            throw KeychainError.writeFailed(underlying: error)
        }

        let readBack: String?
        do {
            readBack = try keychain.getString(Account.selfCheck)
        } catch {
            throw KeychainError.readFailed(underlying: error)
        }

        guard readBack == canary else {
            AppLog.keychain.error("Self-check mismatch: expected=\(canary, privacy: .public), got=\(readBack ?? "<nil>", privacy: .public)")
            throw KeychainError.selfCheckMismatch
        }

        // 自检完清除，避免污染
        try? keychain.remove(Account.selfCheck)
        AppLog.keychain.info("Keychain self-check ok")
    }
}
