//
//  AnySearchContextProviderTests.swift
//  StarcatTests
//
//  验证外部搜索只生成受控、有限的单仓查询。
//

import Testing
@testable import Starcat

@Suite("AnySearch Context Provider")
struct AnySearchContextProviderTests {
    @Test("query 不包含 README 或笔记正文")
    func controlledQueries() {
        let repo = Repo(
            id: 1, owner: "apple", name: "swift", fullName: "apple/swift",
            description: "The Swift programming language", language: "Swift",
            starsCount: 1, forksCount: 1, watchersCount: 1, topics: nil, license: nil,
            homepage: nil, htmlUrl: "https://github.com/apple/swift", cloneUrl: nil,
            sshUrl: nil, isPrivate: false, isFork: false, isArchived: false,
            isStarred: true, pushedAt: nil, createdAt: nil, updatedAt: nil,
            starredAt: nil, cachedAt: nil
        )
        let queries = AnySearchContextProvider.queries(for: repo)
        #expect(queries.count == 2)
        #expect(queries.allSatisfy { $0.contains("apple/swift") })
        #expect(queries.joined().count < 400)
    }

    @Test("私有仓库默认禁止外部上下文")
    func privateRepoGate() {
        #expect(!AnySearchContextProvider.allowsExternalContext(
            repoIsPrivate: true,
            enabled: true,
            allowPrivate: false
        ))
        #expect(AnySearchContextProvider.allowsExternalContext(
            repoIsPrivate: true,
            enabled: true,
            allowPrivate: true
        ))
        #expect(!AnySearchContextProvider.allowsExternalContext(
            repoIsPrivate: false,
            enabled: false,
            allowPrivate: true
        ))
    }
}
