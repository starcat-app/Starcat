//
//  RAGBackendConnectionSettingsTests.swift
//  StarcatTests
//
//  Meilisearch/Qdrant 设置草稿的保存与竞态回归；不连接真实后端、不读取真实凭据。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("RAG backend connection settings")
struct RAGBackendConnectionSettingsTests {
    private enum Failure: Error { case offline }

    /// 每个用例使用独立 UserDefaults 和内存 Keychain，避免配置互相污染。
    private func settings(_ keychain: InMemoryKeychain) -> AppSettings {
        AppSettings(
            defaults: UserDefaults(suiteName: "test.starcat.ragConnection.\(UUID().uuidString)")!,
            keychain: keychain
        )
    }

    @Test("失败保留两种后端原有端点、名称和凭据", arguments: [false, true])
    func failurePreservesSavedConfiguration(qdrant: Bool) async throws {
        let keychain = InMemoryKeychain()
        let settings = settings(keychain)
        let original = settings.ragBackendConfiguration
        let keyID = qdrant ? RAGBackendConfiguration.qdrantKeychainID : RAGBackendConfiguration.meilisearchKeychainID
        try keychain.storeAIKey("saved-key", forProvider: keyID)
        let model = RAGBackendConnectionSettingsModel(keychain: keychain)
        model.load(settings: settings)
        if qdrant {
            model.qdrant.endpoint = "https://qdrant.example.com"
            model.qdrant.collectionName = "new_collection"
            model.qdrantAPIKey = "draft-key"
            await model.testQdrant(settings: settings) { _, _ in throw Failure.offline }
        } else {
            model.meilisearch.endpoint = "https://meili.example.com"
            model.meilisearch.indexName = "new_index"
            model.meilisearchAPIKey = "draft-key"
            await model.testMeilisearch(settings: settings) { _, _ in throw Failure.offline }
        }
        #expect(settings.ragBackendConfiguration == original)
        #expect(try keychain.loadAIKey(forProvider: keyID) == "saved-key")
        let test = qdrant ? model.vectorTest : model.keywordTest
        #expect(test.result == nil)
        #expect(test.errorMessage != nil)
        #expect(!test.isTesting)
    }

    @Test("成功后只保存已测试后端的快照，不覆盖另一后端", arguments: [false, true])
    func successCommitsOnlyTestedBackend(qdrant: Bool) async throws {
        let keychain = InMemoryKeychain()
        let settings = settings(keychain)
        let original = settings.ragBackendConfiguration
        let model = RAGBackendConnectionSettingsModel(keychain: keychain)
        model.load(settings: settings)
        if qdrant {
            model.qdrant.endpoint = "https://qdrant.example.com"
            model.qdrant.collectionName = "new_collection"
            model.qdrantAPIKey = " draft-key "
            await model.testQdrant(settings: settings) { configuration, key in
                #expect(configuration == model.qdrant)
                #expect(key == "draft-key")
                #expect(settings.ragBackendConfiguration == original)
                // 另一连接的变化在保存时合并，不能用测试开始时的整份配置覆盖它。
                var current = settings.ragBackendConfiguration
                current.meilisearch.indexName = "parallel_index"
                settings.ragBackendConfiguration = current
            }
            #expect(settings.ragBackendConfiguration.qdrant == model.qdrant)
            #expect(settings.ragBackendConfiguration.meilisearch.indexName == "parallel_index")
            #expect(try keychain.loadAIKey(forProvider: RAGBackendConfiguration.qdrantKeychainID) == "draft-key")
        } else {
            model.meilisearch.endpoint = "https://meili.example.com"
            model.meilisearch.indexName = "new_index"
            model.meilisearchAPIKey = " draft-key "
            await model.testMeilisearch(settings: settings) { configuration, key in
                #expect(configuration == model.meilisearch)
                #expect(key == "draft-key")
                #expect(settings.ragBackendConfiguration == original)
                var current = settings.ragBackendConfiguration
                current.qdrant.collectionName = "parallel_collection"
                settings.ragBackendConfiguration = current
            }
            #expect(settings.ragBackendConfiguration.meilisearch == model.meilisearch)
            #expect(settings.ragBackendConfiguration.qdrant.collectionName == "parallel_collection")
            #expect(try keychain.loadAIKey(forProvider: RAGBackendConfiguration.meilisearchKeychainID) == "draft-key")
        }
        let test = qdrant ? model.vectorTest : model.keywordTest
        #expect(test.result != nil)
        #expect(test.errorMessage == nil)
    }

    @Test("字段变化或切换后端后，旧测试不能保存", arguments: [0, 1, 2, 3, 4])
    func editingInvalidatesPendingTest(change: Int) async throws {
        let keychain = InMemoryKeychain()
        let settings = settings(keychain)
        let original = settings.ragBackendConfiguration
        let model = RAGBackendConnectionSettingsModel(keychain: keychain)
        model.load(settings: settings)
        var continuation: CheckedContinuation<Void, Never>?
        let task = Task {
            await model.testQdrant(settings: settings) { _, _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        switch change {
        case 0: model.qdrant.endpoint = "https://new.example.com"
        case 1: model.qdrant.collectionName = "changed_collection"
        case 2: model.qdrant.vectorName = "changed_vector"
        case 3: model.qdrantAPIKey = "new-key"
        default: model.vectorTest.invalidate()
        }
        pending.resume()
        await task.value
        #expect(settings.ragBackendConfiguration == original)
        #expect(try keychain.loadAIKey(forProvider: RAGBackendConfiguration.qdrantKeychainID) == nil)
        #expect(model.vectorTest.result == nil)
        #expect(model.vectorTest.errorMessage == nil)
    }

    @Test("凭据保存失败不能发布成功或改变端点", arguments: [false, true])
    func keychainFailureIsNotSuccess(qdrant: Bool) async {
        let keychain = InMemoryKeychain(rejectsAIKeyWrites: true)
        let settings = settings(keychain)
        let original = settings.ragBackendConfiguration
        let model = RAGBackendConnectionSettingsModel(keychain: keychain)
        model.load(settings: settings)
        if qdrant {
            model.qdrant.endpoint = "https://qdrant.example.com"
            model.qdrantAPIKey = "draft"
            await model.testQdrant(settings: settings) { _, _ in }
        } else {
            model.meilisearch.endpoint = "https://meili.example.com"
            model.meilisearchAPIKey = "draft"
            await model.testMeilisearch(settings: settings) { _, _ in }
        }
        let test = qdrant ? model.vectorTest : model.keywordTest
        #expect(test.result == nil)
        #expect(test.errorMessage != nil)
        #expect(settings.ragBackendConfiguration == original)
    }

    @Test("修正失败草稿可重试成功，重新加载不覆盖草稿")
    func correctedDraftCanRetry() async {
        let keychain = InMemoryKeychain()
        let settings = settings(keychain)
        let model = RAGBackendConnectionSettingsModel(keychain: keychain)
        model.load(settings: settings)
        model.meilisearch.indexName = "bad index"
        await model.testMeilisearch(settings: settings) { _, _ in
            Issue.record("Invalid names must be rejected before sending a request")
        }
        #expect(model.keywordTest.errorMessage != nil)
        model.meilisearch.indexName = "valid_index"
        #expect(model.keywordTest.errorMessage == nil)
        model.load(settings: settings)
        #expect(model.meilisearch.indexName == "valid_index")
        await model.testMeilisearch(settings: settings) { _, _ in }
        #expect(model.keywordTest.result != nil)
        #expect(settings.ragBackendConfiguration.meilisearch.indexName == "valid_index")
    }
}
