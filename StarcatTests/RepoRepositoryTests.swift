//
//  RepoRepositoryTests.swift
//  StarcatTests
//
//  验证 RepoRepository 的 upsert + 取消 star 标记 + 计数。
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("RepoRepository")
struct RepoRepositoryTests {

    /// D-01：原 `RepoRepository` 改名 `GRDBRepoRepository`，测试构造具体实现仍直接 new
    /// （只在协议方法上验证，等同覆盖协议 conformance）。
    private func makeRepo() throws -> (GRDBRepoRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        return (repo, db)
    }

    private func makeDTO(id: Int64, name: String) -> StarredRepoDTO {
        let user = GitHubUserDTO(id: 1, login: "tester", name: nil, avatarUrl: nil,
                                 publicRepos: nil, followers: nil, following: nil,
                                 bio: nil, company: nil, location: nil, email: nil,
                                 blog: nil, twitterUsername: nil, htmlUrl: nil)
        let repo = GitHubRepoDTO(
            id: id,
            name: name,
            fullName: "tester/\(name)",
            owner: user,
            description: "desc \(name)",
            language: "Swift",
            stargazersCount: 10,
            forksCount: 1,
            watchersCount: 2,
            topics: ["a", "b"],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/tester/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil
        )
        return StarredRepoDTO(starredAt: "2026-05-29T10:00:00Z", repo: repo)
    }

    @Test("upsert 后 starredCount 增长")
    func upsertAndCount() async throws {
        let (repo, _) = try makeRepo()
        let dtos = (1...3).map { makeDTO(id: Int64($0), name: "r\($0)") }
        try await repo.upsertStarred(dtos, userID: 100, syncedAt: Date())

        let count = try await repo.starredCount()
        #expect(count == 3)
    }

    @Test("重复 upsert 同一 id 应去重")
    func upsertIdempotent() async throws {
        let (repo, _) = try makeRepo()
        let dto = makeDTO(id: 7, name: "same")
        try await repo.upsertStarred([dto, dto, dto], userID: 100, syncedAt: Date())

        let count = try await repo.starredCount()
        #expect(count == 1)
    }

    @Test("markUnstarredExcept 将本地多出的 repo 设为 is_starred=0")
    func markUnstarred() async throws {
        let (repo, db) = try makeRepo()
        let dtos = (1...3).map { makeDTO(id: Int64($0), name: "r\($0)") }
        try await repo.upsertStarred(dtos, userID: 100, syncedAt: Date())

        // 远端只剩 id=1, 2
        try await repo.markUnstarredExcept(remoteRepoIDs: [1, 2], userID: 100)

        let starred = try await repo.starredCount()
        #expect(starred == 2)

        // id=3 仍存在但 is_starred=0；笔记/标签若有也保留（这里直接验证 repos 表）
        try await db.writer.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM repos WHERE id = 3 AND is_starred = 0") ?? 0
            #expect(count == 1)
        }
    }

    @Test("markUnstarred 单个 repo：设 is_starred=0 + 删 starred_repos 行")
    func markUnstarredSingle() async throws {
        let (repo, db) = try makeRepo()
        let dtos = (1...3).map { makeDTO(id: Int64($0), name: "r\($0)") }
        try await repo.upsertStarred(dtos, userID: 100, syncedAt: Date())
        #expect(try await repo.starredCount() == 3)

        try await repo.markUnstarred(repoId: 2, userID: 100)

        #expect(try await repo.starredCount() == 2)
        try await db.writer.read { db in
            let starredRow = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM starred_repos WHERE user_id = ? AND repo_id = ?",
                arguments: [100, 2]
            ) ?? 0
            #expect(starredRow == 0)
            // 该 repo 本身仍存在（保留笔记 / 标签）
            let stillExists = try Int.fetchOne(db, sql: "SELECT count(*) FROM repos WHERE id = 2") ?? 0
            #expect(stillExists == 1)
        }
    }

    @Test("topStarred 按 starred_at 倒序返回")
    func topStarred() async throws {
        let (repo, _) = try makeRepo()
        let user = GitHubUserDTO(id: 1, login: "u", name: nil, avatarUrl: nil,
                                 publicRepos: nil, followers: nil, following: nil,
                                 bio: nil, company: nil, location: nil, email: nil,
                                 blog: nil, twitterUsername: nil, htmlUrl: nil)

        func mkdto(id: Int64, starred: String) -> StarredRepoDTO {
            let r = GitHubRepoDTO(
                id: id, name: "n\(id)", fullName: "u/n\(id)", owner: user,
                description: nil, language: nil,
                stargazersCount: 0, forksCount: 0, watchersCount: 0,
                topics: nil, license: nil, homepage: nil,
                htmlUrl: "https://github.com/u/n\(id)",
                cloneUrl: nil, sshUrl: nil,
                isPrivate: false, fork: false, archived: false,
                pushedAt: nil, createdAt: nil, updatedAt: nil
            )
            return StarredRepoDTO(starredAt: starred, repo: r)
        }

        try await repo.upsertStarred([
            mkdto(id: 1, starred: "2026-01-01T00:00:00Z"),
            mkdto(id: 2, starred: "2026-03-01T00:00:00Z"),
            mkdto(id: 3, starred: "2026-02-01T00:00:00Z")
        ], userID: 100, syncedAt: Date())

        let top = try await repo.topStarred(limit: 2)
        #expect(top.count == 2)
        #expect(top.first?.id == 2)
        #expect(top.last?.id == 3)
    }

    // MARK: - Week 3 查询

    /// 构造一个不同语言/名字的小数据集，便于多个 Week 3 查询复用。
    private func seedDataset(_ repo: GRDBRepoRepository) async throws {
        let user = GitHubUserDTO(id: 1, login: "u", name: nil, avatarUrl: nil,
                                 publicRepos: nil, followers: nil, following: nil,
                                 bio: nil, company: nil, location: nil, email: nil,
                                 blog: nil, twitterUsername: nil, htmlUrl: nil)
        func mkdto(id: Int64, name: String, lang: String?, desc: String?) -> StarredRepoDTO {
            let r = GitHubRepoDTO(
                id: id, name: name, fullName: "u/\(name)", owner: user,
                description: desc, language: lang,
                stargazersCount: 0, forksCount: 0, watchersCount: 0,
                topics: nil, license: nil, homepage: nil,
                htmlUrl: "https://github.com/u/\(name)",
                cloneUrl: nil, sshUrl: nil,
                isPrivate: false, fork: false, archived: false,
                pushedAt: nil, createdAt: nil, updatedAt: nil
            )
            return StarredRepoDTO(starredAt: "2026-05-29T10:00:00Z", repo: r)
        }
        let dtos: [StarredRepoDTO] = [
            mkdto(id: 1, name: "swift-app",   lang: "Swift",      desc: "ios swift cool"),
            mkdto(id: 2, name: "rust-cli",    lang: "Rust",       desc: "fast rust cli"),
            mkdto(id: 3, name: "py-data",     lang: "Python",     desc: "pandas numpy"),
            mkdto(id: 4, name: "swift-ui",    lang: "Swift",      desc: "another swift project"),
            mkdto(id: 5, name: "no-lang",     lang: nil,          desc: "config repo")
        ]
        try await repo.upsertStarred(dtos, userID: 100, syncedAt: Date())
    }

    @Test("fetchAllStarred 返回全部 is_starred=1 的 repo，按 starred_at 倒序")
    func fetchAllStarred_returnsAll() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let all = try await repo.fetchAllStarred()
        #expect(all.count == 5)
    }

    @Test("fetchUntagged 无 tag 时等于全部")
    func fetchUntagged_returnsAllWhenNoTags() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let untagged = try await repo.fetchUntagged()
        #expect(untagged.count == 5)
    }

    @Test("fetchByLanguage(\"Swift\") 只返回 Swift 仓库")
    func fetchByLanguage_specific() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let swift = try await repo.fetchByLanguage("Swift")
        #expect(swift.count == 2)
        #expect(swift.allSatisfy { $0.language == "Swift" })
    }

    @Test("fetchByLanguage(nil) 只返回 language IS NULL 的 repo")
    func fetchByLanguage_nilMeansNull() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let noLang = try await repo.fetchByLanguage(nil)
        #expect(noLang.count == 1)
        #expect(noLang.first?.language == nil)
    }

    @Test("languageStats 按 count 倒序，空语言以空串呈现")
    func languageStats_orderedByCount() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let stats = try await repo.languageStats()
        // Swift=2 排第一；其余各 1 按字母序：'' < Python < Rust
        #expect(stats.count == 4)
        #expect(stats.first?.language == "Swift")
        #expect(stats.first?.count == 2)
        // 空串代表 language NULL，必然包含
        #expect(stats.contains(where: { $0.language.isEmpty && $0.count == 1 }))
    }

    @Test("searchFTS 命中 name 关键词")
    func searchFTS_matchesName() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let hits = try await repo.searchFTS(query: "swift")
        // name 含 "swift" 的两条 + description 含 "swift" 的两条（重叠）
        #expect(hits.count >= 2)
        #expect(hits.allSatisfy { $0.fullName.contains("swift") || ($0.description?.contains("swift") ?? false) })
    }

    @Test("searchFTS 空 query 退化为全量")
    func searchFTS_emptyMeansAll() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let hits = try await repo.searchFTS(query: "   ")
        #expect(hits.count == 5)
    }

    @Test("searchFTS 多词关键词")
    func searchFTS_multipleTokens() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let hits = try await repo.searchFTS(query: "rust cli")
        #expect(hits.count == 1)
        #expect(hits.first?.name == "rust-cli")
    }
}
