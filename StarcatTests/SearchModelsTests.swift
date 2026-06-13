//
//  SearchModelsTests.swift
//  StarcatTests
//
//  搜索领域模型与历史记录的纯逻辑回归测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Models")
struct SearchModelsTests {
    @Test("RepoIdentity 有双 ID 时优先按 GitHub ID 判断")
    func identityUsesGitHubID() {
        let first = RepoIdentity(ghRepoID: 42, owner: "old", name: "name")
        let renamed = RepoIdentity(ghRepoID: 42, owner: "new", name: "name")
        #expect(first == renamed)
    }

    @Test("RepoIdentity 缺 ID 时按 owner/name 大小写不敏感判断")
    func identityFallsBackToFullName() {
        let first = RepoIdentity(ghRepoID: nil, owner: "OpenAI", name: "Codex")
        let second = RepoIdentity(ghRepoID: nil, owner: "openai", name: "codex")
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @Test("SearchRequest 规范化 query、page 与 perPage")
    func requestNormalizesValues() {
        let request = SearchRequest(query: "  swift  ", page: 0, perPage: 999)
        #expect(request.query == "swift")
        #expect(request.page == 1)
        #expect(request.perPage == 100)
    }
}

@Suite("Search History")
@MainActor
struct SearchHistoryStoreTests {
    @Test("提交历史去重、前移并限制数量")
    func recordDeduplicatesAndLimits() {
        let suite = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SearchHistoryStore(defaults: defaults, limit: 3)

        store.record("Swift")
        store.record("Rust")
        store.record("Go")
        store.record("swift")
        store.record("Kotlin")

        #expect(store.items == ["Kotlin", "swift", "Go"])
        #expect(defaults.stringArray(forKey: "search.center.history") == store.items)
    }

    @Test("删除和清空会同步持久化")
    func removeAndClearPersist() {
        let suite = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SearchHistoryStore(defaults: defaults)

        store.record("Swift")
        store.record("Rust")
        store.remove("SWIFT")
        #expect(store.items == ["Rust"])

        store.clear()
        #expect(store.items.isEmpty)
        #expect(defaults.stringArray(forKey: "search.center.history") == [])
    }
}

