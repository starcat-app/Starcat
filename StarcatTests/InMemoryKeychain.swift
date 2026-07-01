//
//  InMemoryKeychain.swift
//  StarcatTests
//
//  内存版 KeychainManaging 实现，给单元测试用，避免污染开发者本地的真实
//  credentials.json（位于 ~/Library/Application Support/com.starcat.app/）。
//
//  设计要点：
//  - 全部状态在 Dictionary 里，进程内存生命周期；测试结束自然回收
//  - 每个测试用 `InMemoryKeychain()` 各开一份独立实例，绝不共享 shared 状态
//  - ping() 直接返回 ok，不模拟 self-check 失败路径（如要测就单独写 mock）
//  - 线程安全：内部 NSLock 保护 dict（与 KeychainManager 同款锁结构）
//

import Foundation
@testable import Starcat

/// 给测试用的 in-memory KeychainManaging 实现。
/// 只承担「键值存取」语义，不做加密 / 文件 I/O，速度快、无副作用。
final class InMemoryKeychain: KeychainManaging, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    // MARK: - GitHub Token

    func storeGithubToken(_ token: String) throws {
        setValue(token, forKey: "github_access_token")
    }

    func loadGithubToken() throws -> String? {
        value(forKey: "github_access_token")
    }

    func deleteGithubToken() throws {
        setValue(nil, forKey: "github_access_token")
    }

    // MARK: - AI Key（兼容老接口 + provider-keyed 接口）

    func storeAIKey(_ key: String) throws {
        setValue(key, forKey: "ai_api_key")
    }

    func loadAIKey() throws -> String? {
        value(forKey: "ai_api_key")
    }

    func deleteAIKey() throws {
        setValue(nil, forKey: "ai_api_key")
    }

    func storeAIKey(_ key: String, forProvider providerID: String) throws {
        setValue(key, forKey: "ai_api_key::\(providerID)")
    }

    func loadAIKey(forProvider providerID: String) throws -> String? {
        // 与真实 KeychainManager 保持一致：providerID 维度找不到时回退全局
        value(forKey: "ai_api_key::\(providerID)") ?? value(forKey: "ai_api_key")
    }

    func deleteAIKey(forProvider providerID: String) throws {
        setValue(nil, forKey: "ai_api_key::\(providerID)")
    }

    // MARK: - R-01 自建后端服务 API Key（trending / weekly / sharing）

    func storeServiceAPIKey(_ key: String, forService serviceID: String) throws {
        setValue(key, forKey: "service_api_key::\(serviceID)")
    }

    func loadServiceAPIKey(forService serviceID: String) throws -> String? {
        value(forKey: "service_api_key::\(serviceID)")
    }

    func deleteServiceAPIKey(forService serviceID: String) throws {
        setValue(nil, forKey: "service_api_key::\(serviceID)")
    }

    // MARK: - Chrome Companion Token

    func storeCompanionToken(_ token: String) throws {
        setValue(token, forKey: "companion_bearer_token")
    }

    func loadCompanionToken() throws -> String? {
        value(forKey: "companion_bearer_token")
    }

    func deleteCompanionToken() throws {
        setValue(nil, forKey: "companion_bearer_token")
    }

    func deleteAllCredentials() throws {
        reset()
    }

    // MARK: - ping

    func ping() throws {
        // mock 永远健康，不模拟 selfCheckMismatch 错误（如要测错误路径单独写）
    }

    // MARK: - 测试辅助（非 protocol 方法，仅 mock 自用）

    /// 清空所有键，便于跨测试复用同一实例。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    /// 调试用：检查内部存储状态（不参与 KeychainManaging 协议）。
    var snapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: - 私有

    private func setValue(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value, !value.isEmpty {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    private func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let v = storage[key]
        return (v?.isEmpty == false) ? v : nil
    }
}
