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

    private func makeRepo() throws -> (RepoRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        let repo = RepoRepository(database: db)
        return (repo, db)
    }

    private func makeDTO(id: Int64, name: String) -> StarredRepoDTO {
        let user = GitHubUserDTO(id: 1, login: "tester", name: nil, avatarUrl: nil)
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

    @Test("topStarred 按 starred_at 倒序返回")
    func topStarred() async throws {
        let (repo, _) = try makeRepo()
        let user = GitHubUserDTO(id: 1, login: "u", name: nil, avatarUrl: nil)

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
}
