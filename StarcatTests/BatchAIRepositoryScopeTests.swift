//
//  BatchAIRepositoryScopeTests.swift
//  StarcatTests
//
//  验证手动批量 AI 整理不会把“已选仓库”错误扩大为全部未分类仓库。
//

import Testing
@testable import Starcat

@Suite("Batch AI Repository Scope")
@MainActor
struct BatchAIRepositoryScopeTests {

    @Test("已选范围固定使用值快照且不会读取未分类全集")
    func selectedScopeUsesSnapshot() async {
        var repo = Repo.makeMinimal(owner: "acme", name: "selected")
        repo.id = 101
        let scope = BatchAIRepositoryScope.selected([repo])

        let resolved = await scope.resolveRepositories {
            Issue.record("已选范围不应读取未分类全集")
            return []
        }

        #expect(scope.isSelectionScoped)
        #expect(scope.pendingCount(untaggedCount: 99) == 1)
        #expect(resolved.map(\.id) == [101])
    }

    @Test("全部未分类范围在开始时读取最新仓库")
    func allUntaggedScopeFetchesAtStart() async {
        var repo = Repo.makeMinimal(owner: "acme", name: "untagged")
        repo.id = 202
        let scope = BatchAIRepositoryScope.allUntagged

        let resolved = await scope.resolveRepositories { [repo] }

        #expect(!scope.isSelectionScoped)
        #expect(scope.pendingCount(untaggedCount: 7) == 7)
        #expect(resolved.map(\.id) == [202])
    }

    @Test("多选范围排除已有标签仓库并保持顺序")
    func selectedScopeFiltersTaggedRepositories() {
        var first = Repo.makeMinimal(owner: "acme", name: "first")
        first.id = 301
        var tagged = Repo.makeMinimal(owner: "acme", name: "tagged")
        tagged.id = 302
        var last = Repo.makeMinimal(owner: "acme", name: "last")
        last.id = 303
        let existingTag = Tag.fixture(id: "swift", name: "Swift")

        let filtered = BatchAIRepositoryScope.filterUntaggedRepositories(
            [first, tagged, last],
            tagAssignments: [tagged.id: [existingTag]]
        )

        #expect(filtered.map(\.id) == [301, 303])
    }
}
