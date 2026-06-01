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
///
/// ⚠️ DEBUG 编译临时方案：
/// 在 macOS App Sandbox + ad-hoc 签名下，Keychain item 跨构建经常无法读回
/// （表现为每次启动都要重新登录）。彻底修复需要 Apple ID Team 签名 + `keychain-access-groups`
/// entitlement。在那之前，DEBUG 编译走"Keychain + 文件 fallback"双写策略：
/// - store：先写 Keychain，再写文件（即使 Keychain 失败也继续）
/// - load：先读 Keychain；miss 再读文件
/// - delete：两边都清
///
/// 详情见 `docs/工程进度/2026-05-30-Keychain-临时绕过方案.md`。
/// 发布前必须按文档切回纯 Keychain。
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

    // MARK: - DEBUG token 文件 fallback

    #if DEBUG
    /// DEBUG 期 token 落盘路径：沙盒内 Application Support/com.starcat.app/dev-github-token.txt
    /// 沙盒目录跨 Xcode 构建保持稳定，不受 codesign hash 变化影响。
    private static let devTokenFileURL: URL? = {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dev-github-token.txt")
    }()
    #endif

    // MARK: - GitHub Token

    func storeGithubToken(_ token: String) throws {
        // Keychain 写入：失败不阻塞，DEBUG 期文件 fallback 兜底
        var keychainWriteSucceeded = false
        do {
            try keychain.set(token, key: Account.githubToken)
            keychainWriteSucceeded = true
            AppLog.keychain.info("storeGithubToken: keychain write ok")
        } catch {
            AppLog.keychain.warning("storeGithubToken: keychain write failed: \(error.localizedDescription, privacy: .public)")
            #if !DEBUG
            // RELEASE 模式下没有文件 fallback，直接报错
            throw KeychainError.writeFailed(underlying: error)
            #endif
        }

        #if DEBUG
        // DEBUG 双写：即使 Keychain 成功也写文件，下次启动若 Keychain 不可读会自动回退
        if let url = Self.devTokenFileURL {
            do {
                try token.write(to: url, atomically: true, encoding: .utf8)
                AppLog.keychain.info("storeGithubToken: [DEBUG] file fallback write ok at \(url.lastPathComponent, privacy: .public)")
            } catch {
                AppLog.keychain.error("storeGithubToken: [DEBUG] file fallback write failed: \(error.localizedDescription, privacy: .public)")
                if !keychainWriteSucceeded {
                    throw KeychainError.writeFailed(underlying: error)
                }
            }
        }
        #endif
    }

    func loadGithubToken() throws -> String? {
        // 先试 Keychain
        let keychainValue: String?
        do {
            keychainValue = try keychain.getString(Account.githubToken)
        } catch {
            AppLog.keychain.warning("loadGithubToken: keychain read failed: \(error.localizedDescription, privacy: .public)")
            #if DEBUG
            // DEBUG 下不抛错，继续走文件 fallback
            keychainValue = nil
            #else
            throw KeychainError.readFailed(underlying: error)
            #endif
        }

        if let value = keychainValue, !value.isEmpty {
            AppLog.keychain.info("loadGithubToken: keychain hit")
            return value
        }

        #if DEBUG
        // DEBUG fallback：从文件读
        if let url = Self.devTokenFileURL,
           let token = try? String(contentsOf: url, encoding: .utf8),
           !token.isEmpty {
            AppLog.keychain.warning("loadGithubToken: [DEBUG] keychain miss, fell back to file (跨构建持久化绕过)")
            return token
        }
        #endif

        AppLog.keychain.info("loadGithubToken: miss")
        return nil
    }

    func deleteGithubToken() throws {
        // Keychain 删除：失败不抛（可能本来就没有）
        do {
            try keychain.remove(Account.githubToken)
            AppLog.keychain.info("deleteGithubToken: keychain removed")
        } catch {
            AppLog.keychain.warning("deleteGithubToken: keychain remove failed: \(error.localizedDescription, privacy: .public)")
        }

        #if DEBUG
        // DEBUG fallback：清文件
        if let url = Self.devTokenFileURL {
            try? FileManager.default.removeItem(at: url)
            AppLog.keychain.info("deleteGithubToken: [DEBUG] file fallback removed")
        }
        #endif
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
