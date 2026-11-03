//
//  RAGBackendConnectionSettingsModel.swift
//  Starcat
//
//  外部索引后端的连接草稿。端点、索引名称与凭据通过同一快照测试，成功后一起保存。
//

import Foundation
import Observation

/// 后端选择和 SQLite 回退仍即时生效；远程连接字段只有通过测试才替换已保存配置。
@MainActor
@Observable
final class RAGBackendConnectionSettingsModel {
    var meilisearch = RAGMeilisearchConfiguration() {
        didSet { if oldValue != meilisearch { keywordTest.invalidate() } }
    }
    var qdrant = RAGQdrantConfiguration() {
        didSet { if oldValue != qdrant { vectorTest.invalidate() } }
    }
    var meilisearchAPIKey = "" {
        didSet { if oldValue != meilisearchAPIKey { keywordTest.invalidate() } }
    }
    var qdrantAPIKey = "" {
        didSet { if oldValue != qdrantAPIKey { vectorTest.invalidate() } }
    }
    let keywordTest = SettingsConnectionTest<Void>()
    let vectorTest = SettingsConnectionTest<Void>()
    private let keychain: any KeychainManaging
    private var isLoaded = false

    /// 测试注入内存凭据库，不读取开发者实际 Keychain。
    init(keychain: any KeychainManaging = KeychainManager.shared) {
        self.keychain = keychain
    }

    /// 每次页面会话只加载一次，展开/折叠不会覆盖尚未提交的草稿。
    func load(settings: AppSettings) {
        guard !isLoaded else { return }
        isLoaded = true
        meilisearch = settings.ragBackendConfiguration.meilisearch
        qdrant = settings.ragBackendConfiguration.qdrant
        meilisearchAPIKey = (try? keychain.loadAIKey(
            forProvider: RAGBackendConfiguration.meilisearchKeychainID
        )) ?? ""
        qdrantAPIKey = (try? keychain.loadAIKey(
            forProvider: RAGBackendConfiguration.qdrantKeychainID
        )) ?? ""
    }

    /// 先验证配置和连接，再同步保存 Key 与普通偏好；过期或失败的测试不会触及存储。
    func testMeilisearch(
        settings: AppSettings,
        probe: @MainActor (RAGMeilisearchConfiguration, String) async throws -> Void
    ) async {
        let configuration = meilisearch
        let key = meilisearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await keywordTest.run {
            if let message = configuration.validationMessage {
                throw RAGExternalBackendError.invalidConfiguration(message)
            }
            try await probe(configuration, key)
        } save: { _ in
            try keychain.storeAIKey(key, forProvider: RAGBackendConfiguration.meilisearchKeychainID)
            var saved = settings.ragBackendConfiguration
            saved.meilisearch = configuration
            settings.ragBackendConfiguration = saved
        }
    }

    /// Qdrant 独立持有测试状态，修改关键词后端不会取消另一条连接的测试。
    func testQdrant(
        settings: AppSettings,
        probe: @MainActor (RAGQdrantConfiguration, String) async throws -> Void
    ) async {
        let configuration = qdrant
        let key = qdrantAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await vectorTest.run {
            if let message = configuration.validationMessage {
                throw RAGExternalBackendError.invalidConfiguration(message)
            }
            try await probe(configuration, key)
        } save: { _ in
            try keychain.storeAIKey(key, forProvider: RAGBackendConfiguration.qdrantKeychainID)
            var saved = settings.ragBackendConfiguration
            saved.qdrant = configuration
            settings.ragBackendConfiguration = saved
        }
    }
}
