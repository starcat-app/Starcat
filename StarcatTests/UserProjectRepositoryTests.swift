//
//  UserProjectRepositoryTests.swift
//  StarcatTests
//
//  验证“我的项目”关系与 Repo 用户数据隔离、generation 对账和数据库筛选。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("UserProjectRepository")
struct UserProjectRepositoryTests {
    private func makeSUT() throws -> (GRDBUserProjectRepository, GRDBRepoRepository, any DatabaseManaging) {
        let database = try InMemoryDatabaseManager()
        return (
            GRDBUserProjectRepository(database: database),
            GRDBRepoRepository(database: database),
            database
        )
    }

    private func remote(
        id: Int64,
        owner: String = "tester",
        name: String,
        affiliation: ProjectAffiliation = .owner,
        visibility: ProjectVisibility = .public,
        permission: ProjectPermission = .admin
    ) -> RemoteUserProject {
        let user = GitHubUserDTO(
            id: 1,
            login: owner,
            name: nil,
            avatarUrl: nil,
            publicRepos: nil,
            followers: nil,
            following: nil,
            bio: nil,
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: nil
        )
        return RemoteUserProject(
            repo: GitHubRepoDTO(
                id: id,
                name: name,
                fullName: "\(owner)/\(name)",
                owner: user,
                description: "project \(name)",
                language: "Swift",
                stargazersCount: Int(id) * 10,
                forksCount: 1,
                watchersCount: 2,
                topics: ["swift"],
                license: nil,
                homepage: nil,
                htmlUrl: "https://github.com/\(owner)/\(name)",
                cloneUrl: nil,
                sshUrl: nil,
                isPrivate: visibility == .private,
                fork: false,
                archived: false,
                pushedAt: nil,
                createdAt: nil,
                updatedAt: nil,
                openIssuesCount: nil,
                defaultBranch: "main",
                disabled: nil,
                isTemplate: nil,
                score: nil
            ),
            affiliation: affiliation,
            ownerType: affiliation == .owner ? .user : .organization,
            visibility: visibility,
            permission: permission,
            installationId: nil
        )
    }

    @Test("项目 upsert 保留 Star 和用户内容并写入当天 snapshot")
    func upsertPreservesIndependentRelations() async throws {
        let (projects, stars, database) = try makeSUT()
        let item = remote(id: 11, name: "shared")
        let starred = StarredRepoDTO(starredAt: "2026-07-01T00:00:00Z", repo: item.repo)
        try await stars.upsertStarred([starred], userID: 7, syncedAt: Date(timeIntervalSince1970: 100))

        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo_notes (repo_id, content, status, library_state, is_ai_generated)
                    VALUES (11, 'keep-note', 'using', 'in_library', 0)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO tags (id, name, created_at, updated_at)
                    VALUES ('tag-1', '重要', '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO repo_tags (repo_id, tag_id, created_at)
                    VALUES (11, 'tag-1', '2026-07-01T00:00:00Z')
                    """
            )
            try db.execute(sql: "INSERT INTO repo_pins (repo_id, pinned_at) VALUES (11, 100)")
        }

        try await projects.upsertPage(
            [item],
            userID: 7,
            authorizationSource: .oauth,
            generation: "g1",
            seenAt: Date(timeIntervalSince1970: 200)
        )

        let saved = try #require(try await stars.findById(11))
        #expect(saved.isStarred)
        #expect(saved.starredAt == "2026-07-01T00:00:00Z")
        try await database.writer.read { db in
            let note = try String.fetchOne(db, sql: "SELECT content FROM repo_notes WHERE repo_id = 11")
            let pinCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo_pins WHERE repo_id = 11")
            let tagCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo_tags WHERE repo_id = 11")
            let status = try String.fetchOne(db, sql: "SELECT status FROM repo_notes WHERE repo_id = 11")
            let libraryState = try String.fetchOne(
                db,
                sql: "SELECT library_state FROM repo_notes WHERE repo_id = 11"
            )
            let snapshotCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM repo_star_history_points WHERE repo_id = 11"
            )
            #expect(note == "keep-note")
            #expect(pinCount == 1)
            #expect(tagCount == 1)
            #expect(status == "using")
            #expect(libraryState == "in_library")
            #expect(snapshotCount == 1)
        }
    }

    @Test("失败 generation 保留旧关系，成功后才清理")
    func generationCleanupOnlyAfterSuccess() async throws {
        let (projects, _, _) = try makeSUT()
        let first = [
            remote(id: 21, name: "kept"),
            remote(id: 22, name: "removed")
        ]
        try await projects.upsertPage(
            first,
            userID: 7,
            authorizationSource: .oauth,
            generation: "g1",
            seenAt: Date(timeIntervalSince1970: 100)
        )
        try await projects.completeGeneration(
            userID: 7,
            affiliation: .owner,
            authorizationSource: .oauth,
            generation: "g1",
            etag: "etag-1",
            completedAt: Date(timeIntervalSince1970: 100)
        )

        try await projects.upsertPage(
            [remote(id: 21, name: "kept")],
            userID: 7,
            authorizationSource: .oauth,
            generation: "g2",
            seenAt: Date(timeIntervalSince1970: 200)
        )
        try await projects.failGeneration(
            userID: 7,
            affiliation: .owner,
            authorizationSource: .oauth,
            generation: "g2",
            errorCode: "network",
            failedAt: Date(timeIntervalSince1970: 200)
        )
        #expect(try await projects.count(userID: 7, filter: .init()) == 2)

        try await projects.completeGeneration(
            userID: 7,
            affiliation: .owner,
            authorizationSource: .oauth,
            generation: "g2",
            etag: "etag-2",
            completedAt: Date(timeIntervalSince1970: 300)
        )
        #expect(try await projects.count(userID: 7, filter: .init()) == 1)
        let state = try #require(
            try await projects.fetchSyncState(
                userID: 7,
                affiliation: .owner,
                authorizationSource: .oauth
            )
        )
        #expect(state.syncStatus == .succeeded)
        #expect(state.etag == "etag-2")
        #expect(state.lastSuccessAt != nil)
    }

    @Test("项目筛选可叠加 affiliation、组织、可见性、权限和搜索")
    func filtersComposeInDatabase() async throws {
        let (projects, _, _) = try makeSUT()
        let rows = [
            remote(id: 31, owner: "tester", name: "personal"),
            remote(
                id: 32,
                owner: "Acme",
                name: "private-tool",
                affiliation: .organizationMember,
                visibility: .private,
                permission: .maintain
            ),
            remote(
                id: 33,
                owner: "Other",
                name: "public-tool",
                affiliation: .organizationMember,
                permission: .pull
            )
        ]
        try await projects.upsertPage(
            rows,
            userID: 7,
            authorizationSource: .githubApp,
            generation: "g1",
            seenAt: Date()
        )

        var filter = UserProjectFilter()
        filter.affiliations = [.organizationMember]
        filter.organizationLogins = ["Acme"]
        filter.visibilities = [.private]
        filter.permissions = [.maintain]
        filter.searchText = "tool"
        let result = try await projects.fetchPage(userID: 7, filter: filter, limit: 20, offset: 0)

        #expect(result.map(\.repo.id) == [32])
        #expect(result.first?.project.ownerLogin == "Acme")
    }

    @Test("项目列表分页使用稳定顺序且返回真实总数")
    func paginationUsesStableDatabaseOrder() async throws {
        let (projects, _, _) = try makeSUT()
        try await projects.upsertPage(
            [
                remote(id: 51, name: "one"),
                remote(id: 52, name: "two"),
                remote(id: 53, name: "three")
            ],
            userID: 7,
            authorizationSource: .oauth,
            generation: "g1",
            seenAt: Date(timeIntervalSince1970: 100)
        )

        let page = try await projects.fetchPage(
            userID: 7,
            filter: .init(),
            limit: 2,
            offset: 1
        )

        #expect(try await projects.count(userID: 7, filter: .init()) == 3)
        #expect(page.map(\.repo.id) == [52, 51])
    }

    @Test("删除项目关系不删除 Repo、Star 或用户内容")
    func deletingRelationsPreservesRepoData() async throws {
        let (projects, stars, database) = try makeSUT()
        let item = remote(id: 41, name: "retained")
        try await stars.upsertStarred(
            [StarredRepoDTO(starredAt: "2026-07-01T00:00:00Z", repo: item.repo)],
            userID: 7,
            syncedAt: Date()
        )
        try await projects.upsertPage(
            [item],
            userID: 7,
            authorizationSource: .oauth,
            generation: "g1",
            seenAt: Date()
        )
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO repo_notes (repo_id, content, is_ai_generated) VALUES (41, 'keep', 0)"
            )
        }

        try await projects.deleteRelations(userID: 7)

        #expect(try await projects.count(userID: 7, filter: .init()) == 0)
        #expect(try await stars.findById(41) != nil)
        #expect(try await stars.starredCount() == 1)
        try await database.writer.read { db in
            let note = try String.fetchOne(db, sql: "SELECT content FROM repo_notes WHERE repo_id = 41")
            #expect(note == "keep")
        }
    }

    @Test("断开 GitHub App 只删除该凭据来源的关系")
    func deletingGitHubAppRelationsPreservesOAuthFallback() async throws {
        let (projects, _, _) = try makeSUT()
        try await projects.upsertPage(
            [remote(id: 61, name: "public-fallback")],
            userID: 7,
            authorizationSource: .oauth,
            generation: "oauth",
            seenAt: Date()
        )
        try await projects.upsertPage(
            [remote(id: 62, name: "private-project")],
            userID: 7,
            authorizationSource: .githubApp,
            generation: "app",
            seenAt: Date()
        )

        try await projects.deleteRelations(
            userID: 7,
            authorizationSource: .githubApp
        )

        let remaining = try await projects.fetchPage(
            userID: 7,
            filter: .init(),
            limit: 10,
            offset: 0
        )
        #expect(remaining.map(\.repo.id) == [61])
        #expect(remaining.first?.authorizationSource == .oauth)
    }
}
