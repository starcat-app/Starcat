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
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: nil,
            disabled: nil,
            isTemplate: nil,
            score: nil
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

    @Test("findByOwnerName 大小写不敏感匹配 full_name")
    func findByOwnerNameIsCaseInsensitive() async throws {
        let (repo, _) = try makeRepo()
        let owner = GitHubUserDTO(id: 1, login: "JetBrains", name: nil, avatarUrl: nil,
                                  publicRepos: nil, followers: nil, following: nil,
                                  bio: nil, company: nil, location: nil, email: nil,
                                  blog: nil, twitterUsername: nil, htmlUrl: nil)
        let dto = StarredRepoDTO(
            starredAt: "2026-05-29T10:00:00Z",
            repo: GitHubRepoDTO(
                id: 42,
                name: "intellij-community",
                fullName: "JetBrains/intellij-community",
                owner: owner,
                description: nil,
                language: "Java",
                stargazersCount: 0,
                forksCount: 0,
                watchersCount: 0,
                topics: nil,
                license: nil,
                homepage: nil,
                htmlUrl: "https://github.com/JetBrains/intellij-community",
                cloneUrl: nil,
                sshUrl: nil,
                isPrivate: false,
                fork: false,
                archived: false,
                pushedAt: nil,
                createdAt: nil,
                updatedAt: nil,
                openIssuesCount: nil,
                defaultBranch: nil,
                disabled: nil,
                isTemplate: nil,
                score: nil
            )
        )
        try await repo.upsertStarred([dto], userID: 100, syncedAt: Date())

        let hit = try await repo.findByOwnerName(owner: "jetbrains", name: "intellij-community")

        #expect(hit?.id == 42)
        #expect(hit?.fullName == "JetBrains/intellij-community")
        #expect(hit?.isStarred == true)
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
                pushedAt: nil, createdAt: nil, updatedAt: nil,
                openIssuesCount: nil, defaultBranch: nil,
                disabled: nil, isTemplate: nil, score: nil
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
                pushedAt: nil, createdAt: nil, updatedAt: nil,
                openIssuesCount: nil, defaultBranch: nil,
                disabled: nil, isTemplate: nil, score: nil
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

    @Test("fetchRecentStarred 只返回最近 N 条且仍按 starred_at 倒序")
    func fetchRecentStarred_respectsLimit() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let recent = try await repo.fetchRecentStarred(limit: 2)
        #expect(recent.count == 2)
        let all = try await repo.fetchAllStarred()
        #expect(recent.map(\.id) == Array(all.prefix(2).map(\.id)))
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

    @Test("languageStats：未分类排第一，其余按 count 倒序")
    func languageStats_orderedByCount() async throws {
        let (repo, _) = try makeRepo()
        try await seedDataset(repo)

        let stats = try await repo.languageStats()
        #expect(stats.count == 4)
        #expect(stats[0].language == "")
        #expect(stats[0].count == 1)
        #expect(stats[1].language == "Swift")
        #expect(stats[1].count == 2)
        let pythonStat = stats.first { $0.language == "Python" }
        let rustStat = stats.first { $0.language == "Rust" }
        #expect(pythonStat?.count == 1)
        #expect(rustStat?.count == 1)
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

    // MARK: - 2026-06-14 召回扩展用例

    /// 用不同 owner 的小数据集，专门覆盖 full_name / owner / 笔记命中。
    /// 不复用 seedDataset 因为它的 owner 都是 "u"，单字符 owner 在 FTS5 token 边界
    /// 上区分度太低（"u" 也是常见 description token），无法干净验证 owner 列召回。
    private func seedOwnerDataset(_ repo: GRDBRepoRepository) async throws {
        func mkUser(login: String) -> GitHubUserDTO {
            GitHubUserDTO(id: 1, login: login, name: nil, avatarUrl: nil,
                          publicRepos: nil, followers: nil, following: nil,
                          bio: nil, company: nil, location: nil, email: nil,
                          blog: nil, twitterUsername: nil, htmlUrl: nil)
        }
        func mkdto(id: Int64, owner: String, name: String, desc: String?) -> StarredRepoDTO {
            let r = GitHubRepoDTO(
                id: id, name: name, fullName: "\(owner)/\(name)", owner: mkUser(login: owner),
                description: desc, language: "Swift",
                stargazersCount: 0, forksCount: 0, watchersCount: 0,
                topics: nil, license: nil, homepage: nil,
                htmlUrl: "https://github.com/\(owner)/\(name)",
                cloneUrl: nil, sshUrl: nil,
                isPrivate: false, fork: false, archived: false,
                pushedAt: nil, createdAt: nil, updatedAt: nil,
                openIssuesCount: nil, defaultBranch: nil,
                disabled: nil, isTemplate: nil, score: nil
            )
            return StarredRepoDTO(starredAt: "2026-05-29T10:00:00Z", repo: r)
        }
        let dtos: [StarredRepoDTO] = [
            mkdto(id: 101, owner: "colbymchenry", name: "codegraph", desc: "knowledge graph mcp"),
            mkdto(id: 102, owner: "vercel",       name: "next-foo",   desc: "react app framework"),
            mkdto(id: 103, owner: "google",       name: "guava",      desc: "java helpers")
        ]
        try await repo.upsertStarred(dtos, userID: 100, syncedAt: Date())
    }

    @Test("searchFTS 单独搜 owner 应能命中（full_name 列拆出 owner token）")
    func searchFTS_matchesOwnerOnly() async throws {
        let (repo, _) = try makeRepo()
        try await seedOwnerDataset(repo)

        // owner 'colbymchenry' 不在 name / description / language / topics 任何列里——
        // 只有 full_name 列里的 'colbymchenry/codegraph' token 化后才能命中。
        // 这个用例如果失败，说明 full_name 没进 FTS。
        let hits = try await repo.searchFTS(query: "colbymchenry")
        #expect(hits.count == 1)
        #expect(hits.first?.name == "codegraph")
    }

    @Test("searchFTS 完整 owner/repo 命中")
    func searchFTS_matchesFullName() async throws {
        let (repo, _) = try makeRepo()
        try await seedOwnerDataset(repo)

        // FTSQuery.sanitize 会包双引号变成 phrase 查询；fts5 unicode61 把 '/' 当切词符,
        // doc 里 'google/guava' 也是 'google' + 'guava' 两个相邻 token,phrase 仍能匹。
        let hits = try await repo.searchFTS(query: "google/guava")
        #expect(hits.count == 1)
        #expect(hits.first?.name == "guava")
    }

    @Test("searchFTS 命中私有笔记内容（notes_fts UNION 召回）")
    func searchFTS_matchesNoteContent() async throws {
        let (repo, db) = try makeRepo()
        try await seedOwnerDataset(repo)

        // 给 repo 102 (next-foo) 加笔记，关键词 "部署失败" 不在 repo 任何字段里。
        let noteRepo = GRDBRepoNoteRepository(database: db)
        try await noteRepo.upsert(RepoNote(
            repoId: 102,
            content: "试过部署失败，已切到别的方案",
            status: "unread",
            isAIGenerated: false,
            editedAt: "2026-06-14T12:00:00Z"
        ))

        let hits = try await repo.searchFTS(query: "部署失败")
        #expect(hits.count == 1)
        #expect(hits.first?.id == 102)
    }

    @Test("searchFTS 同 repo 多源命中只返回一条（OR 合并去重）")
    func searchFTS_dedupAcrossSources() async throws {
        let (repo, db) = try makeRepo()
        try await seedOwnerDataset(repo)

        // codegraph 的 description 已含 "knowledge"；再加一条同关键词笔记。
        // 两路命中（repos_fts + notes_fts）经 GROUP BY repo_id 应只返回 1 条 codegraph。
        let noteRepo = GRDBRepoNoteRepository(database: db)
        try await noteRepo.upsert(RepoNote(
            repoId: 101,
            content: "this knowledge graph is interesting",
            status: "unread",
            isAIGenerated: false,
            editedAt: "2026-06-14T12:00:00Z"
        ))

        let hits = try await repo.searchFTS(query: "knowledge")
        let codegraphHits = hits.filter { $0.id == 101 }
        #expect(codegraphHits.count == 1, "同 repo 在两个 fts 表都命中时不应重复返回")
    }

    @Test("DB Paging: 10k starred repos 首屏只返回 limit 行,全集多选走轻量 projection")
    func listPagingScalesWithLargeDataset() async throws {
        let (repo, db) = try makeRepo()
        let total = 10_000

        try await db.writer.write { db in
            for i in 1...total {
                let id = Int64(i)
                let starredAt = String(format: "%04d-12-31T23:59:59Z", 20_000 - i)
                try db.execute(
                    sql: """
                    INSERT INTO repos (
                        id, owner, name, full_name, description, language,
                        stars_count, forks_count, watchers_count, topics, license,
                        homepage, html_url, clone_url, ssh_url,
                        is_private, is_fork, is_archived, is_starred,
                        pushed_at, created_at, updated_at, starred_at, cached_at
                    ) VALUES (
                        ?, 'owner', ?, ?, 'large fixture', 'Swift',
                        ?, 0, 0, '[]', NULL,
                        NULL, ?, NULL, NULL,
                        0, 0, 0, 1,
                        NULL, NULL, NULL, ?, '2026-06-21T00:00:00Z'
                    )
                    """,
                    arguments: [
                        id,
                        "repo-\(i)",
                        "owner/repo-\(i)",
                        i,
                        "https://github.com/owner/repo-\(i)",
                        starredAt
                    ]
                )
            }
        }

        let firstPage = try await repo.fetchListPage(
            scope: .allStars,
            filters: .empty,
            sort: .starredAtDesc,
            limit: 21,
            offset: 0
        )
        #expect(firstPage.count == 21, "首屏查询只取 pageSize + sentinel,不能退回全量 10k")
        #expect(firstPage.first?.id == 1)

        let totalCount = try await repo.fetchListCount(scope: .allStars, filters: .empty)
        #expect(totalCount == total, "分页首屏只取 21 行,但标题总数必须来自 COUNT(*) 全量")

        let snapshots = try await repo.fetchListSelectionSnapshots(
            scope: .allStars,
            filters: .empty,
            sort: .starredAtDesc
        )
        #expect(snapshots.count == total)
        #expect(snapshots.first?.ghRepoId == 1)
        #expect(snapshots.first?.fullName == "owner/repo-1")
    }

    @Test("DB Paging: fetchListCount 遵守当前 Manage 筛选条件")
    func listCountHonorsManageFilters() async throws {
        let (repo, db) = try makeRepo()
        try await seedDataset(repo)

        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_fork = 1 WHERE id = 2")
            try db.execute(sql: "UPDATE repos SET is_archived = 1 WHERE id = 3")
        }

        #expect(try await repo.fetchListCount(scope: .allStars, filters: .empty) == 5)
        #expect(try await repo.fetchListCount(
            scope: .allStars,
            filters: RepoListFilters(hideArchived: false, hideForks: true, status: nil, selectedTagIDs: [])
        ) == 4)
        #expect(try await repo.fetchListCount(
            scope: .allStars,
            filters: RepoListFilters(hideArchived: true, hideForks: true, status: nil, selectedTagIDs: [])
        ) == 3)
        #expect(try await repo.fetchListCount(scope: .language("Swift"), filters: .empty) == 2)
        #expect(try await repo.fetchListCount(scope: .language(nil), filters: .empty) == 1)
    }

    @Test("DB Paging: GitHub Star List scope 只返回指定分组 repo")
    func githubStarListScopeReturnsGroupedRepos() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one", starredAt: "2026-06-26T03:00:00Z")
        try await db.insertRepoFixture(id: 2, owner: "octo", name: "two", starredAt: "2026-06-26T02:00:00Z")
        try await db.insertRepoFixture(id: 3, owner: "octo", name: "three", starredAt: "2026-06-26T01:00:00Z")

        let lists = GRDBGitHubStarListRepository(database: db)
        try await lists.replaceRemoteSnapshot(
            lists: [
                GitHubStarListRemoteRecord(
                    id: "list-1",
                    name: "Tools",
                    description: nil,
                    isPrivate: false,
                    position: 0,
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/one"),
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/three")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let page = try await repo.fetchListPage(
            scope: .githubStarList("list-1"),
            filters: .empty,
            sort: .starredAtDesc,
            limit: 10,
            offset: 0
        )

        #expect(page.map(\.id) == [1, 3])
        #expect(try await repo.fetchListCount(scope: .githubStarList("list-1"), filters: .empty) == 2)
    }

    @Test("DB Paging: Health 排序按分数倒序且无分数排最后")
    func listPageSortsByHealthScoreDescending() async throws {
        let (repo, db) = try makeRepo()
        let healthRepo = GRDBRepoHealthRepository(database: db)
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "low", starredAt: "2026-06-26T03:00:00Z")
        try await db.insertRepoFixture(id: 2, owner: "octo", name: "missing", starredAt: "2026-06-26T04:00:00Z")
        try await db.insertRepoFixture(id: 3, owner: "octo", name: "high", starredAt: "2026-06-26T02:00:00Z")

        let computedAt = "2026-07-01T12:00:00.000Z"
        let staleAfter = "2026-08-01T12:00:00.000Z"
        for (repoId, score) in [(Int64(1), 55.0), (Int64(3), 91.0)] {
            try await healthRepo.upsert(
                RepoHealthSnapshot(
                    repoId: repoId,
                    overallScore: score,
                    grade: "B",
                    maintenanceScore: score,
                    popularityScore: score,
                    qualityScore: score,
                    securityScore: score,
                    payloadJSON: "{}",
                    computedAt: computedAt,
                    staleAfter: staleAfter,
                    fetchStatus: .success,
                    lastError: nil
                )
            )
        }

        let page = try await repo.fetchListPage(
            scope: .allStars,
            filters: .empty,
            sort: .healthScoreDesc,
            limit: 10,
            offset: 0
        )
        let ids = try await repo.fetchListIDs(
            scope: .allStars,
            filters: .empty,
            sort: .healthScoreDesc
        )

        // id=2 的 starred_at 最新，但没有 health 快照；Health 排序必须把它放到有分数仓库之后。
        #expect(page.map(\.id) == [3, 1, 2])
        #expect(ids == [3, 1, 2])
    }

    @Test("DB Paging: GitHub Star List 未分组 scope 返回没有任何 list 的 starred repo")
    func githubStarListUngroupedScopeReturnsReposWithoutLists() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one", starredAt: "2026-06-26T03:00:00Z")
        try await db.insertRepoFixture(id: 2, owner: "octo", name: "two", starredAt: "2026-06-26T02:00:00Z")
        try await db.insertRepoFixture(id: 3, owner: "octo", name: "three", starredAt: "2026-06-26T01:00:00Z")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 3")
        }

        let lists = GRDBGitHubStarListRepository(database: db)
        try await lists.replaceRemoteSnapshot(
            lists: [
                GitHubStarListRemoteRecord(
                    id: "list-1",
                    name: "Tools",
                    description: nil,
                    isPrivate: false,
                    position: 0,
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "octo/one")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let page = try await repo.fetchListPage(
            scope: .githubStarListUngrouped,
            filters: .empty,
            sort: .starredAtDesc,
            limit: 10,
            offset: 0
        )

        #expect(page.map(\.id) == [2])
        #expect(try await repo.fetchListCount(scope: .githubStarListUngrouped, filters: .empty) == 1)
    }
}
