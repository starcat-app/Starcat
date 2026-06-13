//
//  SearchModelsTests.swift
//  StarcatTests
//
//  搜索领域模型的纯逻辑回归测试。
//
//  历史记录（SearchHistory + GRDBSearchHistoryRepository）的测试已迁到
//  `SearchHistoryRepositoryTests.swift`，原 UserDefaults 版本的
//  `SearchHistoryStoreTests` 在 2026-06-14 持久化升级到 GRDB 后整体废弃。
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
