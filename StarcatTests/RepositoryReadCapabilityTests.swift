//
//  RepositoryReadCapabilityTests.swift
//  StarcatTests
//
//  Repository Read Capability 统一执行语义的单元测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepositoryReadCapability")
struct RepositoryReadCapabilityTests {

    @Test("冻结 Source 在 restriction 不完整时 fail closed")
    func frozenSourceRejectsUnknownRestrictedIDs() async {
        let source = FrozenRepositoryReadCapabilitySource(repositories: [repo(id: 1, fullName: "apple/swift")])
        let executor = RepositoryReadCapabilityExecutor(source: source)

        do {
            _ = try await executor.search(
                RepositorySearchCapabilityRequest(
                    limit: 10,
                    restrictedRepoIDs: [1, 99],
                    requiresCompleteRestriction: true,
                    sort: .stars
                )
            )
            Issue.record("Expected repositoriesOutsideScope")
        } catch let error as RepositoryReadCapabilityError {
            #expect(error == .repositoriesOutsideScope([99]))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("统一 executor 负责过滤、排序、limit 和 total")
    func executorAppliesSharedSearchSemantics() async throws {
        let source = FrozenRepositoryReadCapabilitySource(repositories: [
            repo(id: 1, fullName: "apple/swift", stars: 80),
            repo(id: 2, fullName: "groue/GRDB.swift", stars: 120),
            repo(id: 3, fullName: "swiftlang/swift-markdown", stars: 40)
        ])
        let executor = RepositoryReadCapabilityExecutor(source: source)

        let result = try await executor.search(
            RepositorySearchCapabilityRequest(
                limit: 1,
                restrictedRepoIDs: [1, 2],
                requiresCompleteRestriction: true,
                sort: .stars
            )
        )

        #expect(result.total == 2)
        #expect(result.limit == 1)
        #expect(result.repositories.map(\.id) == [2])
    }

    @Test("统一 selector 支持 ID 优先和大小写不敏感 fullName")
    func executorSelectsFrozenRepository() async throws {
        let expected = repo(id: 7, fullName: "OpenAI/Codex")
        let executor = RepositoryReadCapabilityExecutor(
            source: FrozenRepositoryReadCapabilitySource(repositories: [expected])
        )

        let byID = try await executor.get(RepositoryCapabilitySelector(repoID: 7))
        let byName = try await executor.get(
            RepositoryCapabilitySelector(fullName: "openai/codex")
        )

        #expect(byID == expected)
        #expect(byName == expected)
    }

    @Test("首批 capability definition 均为只读")
    func definitionsAreReadOnly() {
        #expect(RepositoryReadCapabilities.search.id == "repository.search")
        #expect(RepositoryReadCapabilities.get.id == "repository.get")
        #expect(RepositoryReadCapabilities.search.permission == .readOnly)
        #expect(RepositoryReadCapabilities.get.permission == .readOnly)
    }

    /// 构造最小冻结快照，测试不会借助数据库或 UI 状态扩大可见范围。
    private func repo(
        id: Int64,
        fullName: String,
        stars: Int = 1
    ) -> AgentRepoSnapshot {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return AgentRepoSnapshot(
            id: id,
            owner: parts.first ?? "owner",
            name: parts.dropFirst().first ?? "repo",
            fullName: fullName,
            description: "\(fullName) description",
            language: "Swift",
            starsCount: stars,
            topics: [],
            isPrivate: false,
            isStarred: true,
            starredAt: "2026-08-04T00:00:00Z",
            htmlUrl: "https://github.com/\(fullName)"
        )
    }
}
