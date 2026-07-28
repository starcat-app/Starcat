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

    @Test("upsertExternalRepoForLibrary: 未 star 外部 repo 只写 metadata,不创建 starred 关系")
    func upsertExternalRepoForLibraryCreatesUnstarredRepo() async throws {
        let (repo, db) = try makeRepo()
        let dto = makeDTO(id: 9001, name: "external").repo

        let saved = try await repo.upsertExternalRepoForLibrary(repoDTO: dto, syncedAt: Date())

        #expect(saved.id == 9001)
        #expect(saved.isStarred == false)
        #expect(saved.starredAt == nil)
        #expect(try await repo.starredCount() == 0)

        try await db.writer.read { db in
            let relationCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM starred_repos WHERE repo_id = ?",
                arguments: [9001]
            ) ?? 0
            #expect(relationCount == 0)
        }
    }

    @Test("upsertExternalRepoForLibrary: 已 star repo 不会被外部 metadata 写入降级")
    func upsertExternalRepoForLibraryPreservesExistingStarState() async throws {
        let (repo, _) = try makeRepo()
        let starred = makeDTO(id: 9002, name: "already-starred")
        try await repo.upsertStarred([starred], userID: 100, syncedAt: Date())
        let before = try #require(try await repo.findById(9002))

        let saved = try await repo.upsertExternalRepoForLibrary(repoDTO: starred.repo, syncedAt: Date())

        #expect(saved.isStarred == true)
        #expect(saved.starredAt == before.starredAt)
        #expect(try await repo.starredCount() == 1)
    }

    @Test("upsertRepoMetadataForLibrary: 从详情 Repo 写入时不创建 starred 关系")
    func upsertRepoMetadataForLibraryDoesNotCreateStar() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "seed")
        var external = try #require(try await repo.findById(1))
        external.id = 9010
        external.name = "detail-only"
        external.fullName = "external/detail-only"
        external.htmlUrl = "https://github.com/external/detail-only"
        external.isStarred = true
        external.starredAt = "2026-05-29T10:00:00Z"

        let saved = try await repo.upsertRepoMetadataForLibrary(repo: external, syncedAt: Date())

        #expect(saved.id == 9010)
        #expect(saved.isStarred == false)
        #expect(saved.starredAt == nil)
        #expect(try await repo.starredCount() == 1)
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

    @Test("知识库查询包含未 star 已入库 repo,但 starred 查询不被污染")
    func knowledgeQueriesIncludeUnstarredLibraryReposOnlyInKnowledgeScope() async throws {
        let (repo, db) = try makeRepo()
        try await seedDataset(repo)
        let noteRepo = GRDBRepoNoteRepository(database: db)

        let external = makeDTO(id: 9003, name: "library-only").repo
        _ = try await repo.upsertExternalRepoForLibrary(repoDTO: external, syncedAt: Date())
        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)
        try await noteRepo.updateLibraryState(repoId: 9003, state: .inLibrary)

        let knowledge = try await repo.fetchKnowledgeRepos()
        #expect(Set(knowledge.map(\.id)) == [1, 9003])
        #expect(try await repo.knowledgeCount() == 2)
        #expect(try await repo.fetchKnowledgeRepoIDs() == [1, 9003])

        let starred = try await repo.fetchAllStarred()
        #expect(starred.map(\.id).contains(9003) == false)
        #expect(try await repo.fetchListCount(scope: .library, filters: .empty) == 2)

        let libraryPage = try await repo.fetchListPage(
            scope: .library,
            filters: .empty,
            sort: .starredAtDesc,
            limit: 10,
            offset: 0
        )
        #expect(Set(libraryPage.map(\.id)) == [1, 9003])

        var starredFilter = RepoListFilters.empty
        starredFilter.star = .starred
        #expect(try await repo.fetchListCount(scope: .library, filters: starredFilter) == 1)

        var unstarredFilter = RepoListFilters.empty
        unstarredFilter.star = .unstarred
        #expect(try await repo.fetchListCount(scope: .library, filters: unstarredFilter) == 1)
        let unstarredLibraryPage = try await repo.fetchListPage(
            scope: .library,
            filters: unstarredFilter,
            sort: .starredAtDesc,
            limit: 10,
            offset: 0
        )
        #expect(unstarredLibraryPage.map(\.id) == [9003])

        let languageStats = try await repo.knowledgeLanguageStats()
        #expect(languageStats.first { $0.language == "Swift" }?.count == 2)
    }

    @Test("访问状态标记不改变知识库归属")
    func accessStateDoesNotRemoveLibraryRepo() async throws {
        let (repo, db) = try makeRepo()
        try await seedDataset(repo)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)

        try await repo.updateAccessState(
            repoId: 1,
            state: .unavailable,
            reason: "GitHub 404",
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let saved = try #require(try await repo.findById(1))
        #expect(saved.accessState == .unavailable)
        #expect(saved.accessReason == "GitHub 404")
        #expect(saved.accessCheckedAt != nil)
        #expect(try await noteRepo.fetchLibraryState(repoId: 1) == .inLibrary)

        let knowledge = try await repo.fetchKnowledgeRepos()
        #expect(knowledge.map(\.id).contains(1))
        #expect(knowledge.first { $0.id == 1 }?.accessState == .unavailable)
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

    @Test("searchKnowledgeFTS 只返回知识库范围命中")
    func searchKnowledgeFTSRestrictsToLibraryScope() async throws {
        let (repo, db) = try makeRepo()
        try await seedDataset(repo)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)

        let hits = try await repo.searchKnowledgeFTS(query: "swift")
        #expect(hits.map(\.id) == [1])

        let emptyHits = try await repo.searchKnowledgeFTS(query: " ")
        #expect(emptyHits.map(\.id) == [1])
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
        let noteRepo = GRDBRepoNoteRepository(database: db)
        try await seedDataset(repo)

        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_fork = 1 WHERE id = 2")
            try db.execute(sql: "UPDATE repos SET is_archived = 1 WHERE id = 3")
        }
        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)
        try await noteRepo.updateLibraryState(repoId: 4, state: .inLibrary)

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
        #expect(try await repo.fetchListCount(
            scope: .allStars,
            filters: RepoListFilters(hideArchived: false, hideForks: false, status: nil, library: .inLibrary, selectedTagIDs: [])
        ) == 2)
        #expect(try await repo.fetchListCount(
            scope: .allStars,
            filters: RepoListFilters(hideArchived: false, hideForks: false, status: nil, library: .outsideLibrary, selectedTagIDs: [])
        ) == 3)
        #expect(try await repo.fetchListCount(
            scope: .library,
            filters: RepoListFilters(hideArchived: false, hideForks: false, status: nil, library: .outsideLibrary, selectedTagIDs: [])
        ) == 0)
        #expect(try await repo.fetchListCount(
            scope: .library,
            filters: RepoListFilters(
                hideArchived: false,
                hideForks: false,
                status: nil,
                library: .all,
                language: .language("Swift"),
                selectedTagIDs: []
            )
        ) == 2)
        #expect(try await repo.fetchListCount(
            scope: .library,
            filters: RepoListFilters(
                hideArchived: false,
                hideForks: false,
                status: nil,
                library: .all,
                language: .uncategorized,
                selectedTagIDs: []
            )
        ) == 0)
    }

    @Test("DB Paging: 洞察结构化筛选与 RAG 快照口径一致")
    func listCountHonorsInsightsDrillDownFilters() async throws {
        let (repo, database) = try makeRepo()
        let noteRepository = GRDBRepoNoteRepository(database: database)
        try await seedDataset(repo)
        try await noteRepository.updateLibraryState(repoId: 1, state: .inLibrary)
        try await noteRepository.updateLibraryState(repoId: 4, state: .inLibrary)

        let tag = Tag.fixture(id: "organized", name: "Organized")
        try await GRDBTagRepository(database: database).create(tag)
        try await GRDBRepoTagRepository(database: database).addTag(repoId: 1, tagId: tag.id)
        try await GRDBRepoHealthRepository(database: database).upsert(
            RepoHealthSnapshot(
                repoId: 4,
                overallScore: 45,
                grade: "D",
                maintenanceScore: 40,
                popularityScore: 50,
                qualityScore: 50,
                securityScore: 50,
                payloadJSON: "{}",
                computedAt: "2026-07-27T00:00:00Z",
                staleAfter: "2026-07-28T00:00:00Z",
                fetchStatus: .success,
                lastError: nil
            )
        )
        try await GRDBOpenSSFScoreRepository(database: database).upsert(
            OpenSSFScoreRecord(
                repoId: 4,
                fetchStatus: .success,
                aggregateScore: 4,
                checksJSON: nil,
                scoreDate: "2026-07-27",
                fetchedAt: "2026-07-27T00:00:00Z",
                lastError: nil
            )
        )

        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES
                    (1, 'readme', '', 'readme', 'readme', 'README', 'readme:0',
                     0, '', 'README', 'ready', 'ready-hash', 1, 0,
                     'embed-v1', 'ready', datetime('now'), datetime('now')),
                    (4, 'metadata', '', 'metadata', 'metadata', 'Metadata', 'metadata:0',
                     0, '', 'Metadata', 'stale', 'stale-hash', 1, 0,
                     'old-model', 'stale', datetime('now'), datetime('now'))
                """)
        }

        func routeFilters(_ action: InsightsSelection) throws -> RepoListFilters {
            let route = try #require(
                InsightsDrillDownRouter.route(
                    scope: .knowledge,
                    target: .action(action),
                    embeddingModel: "embed-v1"
                )
            )
            #expect(route.selection == .library)
            return route.filters.repoListFilters(selectedTagIDs: [])
        }

        let tagMissing = try routeFilters(.untagged)
        #expect(try await repo.fetchListCount(scope: .library, filters: tagMissing) == 1)

        let readmeMissing = try routeFilters(.missingReadme)
        #expect(try await repo.fetchListCount(scope: .library, filters: readmeMissing) == 1)

        let indexableMissing = try routeFilters(.missingIndexableContent)
        #expect(try await repo.fetchListCount(scope: .library, filters: indexableMissing) == 0)

        let indexIssues = try routeFilters(.indexIssues)
        #expect(try await repo.fetchListCount(scope: .library, filters: indexIssues) == 1)

        let maintenanceRisk = try routeFilters(.maintenanceRisk)
        #expect(try await repo.fetchListCount(scope: .library, filters: maintenanceRisk) == 1)

        let securityRisk = try routeFilters(.securityRisk)
        #expect(try await repo.fetchListCount(scope: .library, filters: securityRisk) == 1)

        var combined = tagMissing
        combined.status = .unread
        #expect(try await repo.fetchListCount(scope: .library, filters: combined) == 1)

        try await database.writer.write { db in
            let fetchedChunkID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM rag_chunks WHERE repo_id = 4"
            )
            let chunkID = try #require(fetchedChunkID)
            try db.execute(
                sql: """
                    INSERT INTO rag_chunk_overrides (
                        chunk_id, original_title, original_section_path, original_content,
                        is_excluded, updated_at
                    ) VALUES (?, 'Metadata', '', 'stale', 1, datetime('now'))
                    """,
                arguments: [chunkID]
            )
        }

        #expect(try await repo.fetchListCount(scope: .library, filters: indexableMissing) == 1)
        #expect(try await repo.fetchListCount(scope: .library, filters: indexIssues) == 0)
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

    @Test("DB Paging: 我的项目包含未 Star 项目并复用现有组合筛选")
    func myProjectsScopeComposesExistingFilters() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "me", name: "personal")
        try await db.insertRepoFixture(id: 2, owner: "acme", name: "private-tool")
        try await db.insertRepoFixture(id: 3, owner: "other", name: "other-user")
        try await db.insertRepoFixture(id: 4, owner: "me", name: "starred-only")

        try await db.writer.write { db in
            // id=1 模拟“是项目但未 Star”；id=4 模拟“已 Star 但不是项目”。
            try db.execute(sql: "UPDATE repos SET is_starred = 0, starred_at = NULL WHERE id = 1")
            try db.execute(sql: "UPDATE repos SET language = 'Go' WHERE id = 2")
            try db.execute(
                sql: """
                    INSERT INTO user_projects (
                        user_id, repo_id, affiliation, owner_login, owner_type, visibility,
                        permission, authorization_source, installation_id, generation,
                        last_seen_at, created_at, updated_at
                    ) VALUES
                        (7, 1, 'owner', 'me', 'user', 'public',
                         'admin', 'oauth', NULL, 'g1',
                         '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z'),
                        (7, 2, 'organization_member', 'acme', 'organization', 'private',
                         'maintain', 'github_app', NULL, 'g1',
                         '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z'),
                        (8, 3, 'owner', 'other', 'user', 'public',
                         'admin', 'oauth', NULL, 'g1',
                         '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO repo_notes (repo_id, content, status, library_state, is_ai_generated)
                    VALUES (1, 'project note', 'using', 'in_library', 0)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO tags (id, name, created_at, updated_at)
                    VALUES ('project-tag', '项目', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO repo_tags (repo_id, tag_id, created_at)
                    VALUES (1, 'project-tag', '2026-07-29T00:00:00Z')
                    """
            )
        }

        let allProjects = try await repo.fetchListPage(
            scope: .myProjects(userID: 7),
            filters: .empty,
            sort: .nameAsc,
            limit: 20,
            offset: 0
        )
        #expect(allProjects.map(\.id) == [2, 1])
        #expect(try await repo.fetchListCount(scope: .myProjects(userID: 7), filters: .empty) == 2)

        var unstarredInLibrary = RepoListFilters.empty
        unstarredInLibrary.star = .unstarred
        unstarredInLibrary.library = .inLibrary
        unstarredInLibrary.language = .language("Swift")
        unstarredInLibrary.status = .using
        unstarredInLibrary.selectedTagIDs = ["project-tag"]
        let filtered = try await repo.fetchListPage(
            scope: .myProjects(userID: 7),
            filters: unstarredInLibrary,
            sort: .nameAsc,
            limit: 20,
            offset: 0
        )
        #expect(filtered.map(\.id) == [1])

        // 相同 scope 仍按 user_id 隔离；普通 Star 列表也不能被项目关系扩张。
        #expect(try await repo.fetchListCount(scope: .myProjects(userID: 8), filters: .empty) == 1)
        #expect(try await repo.fetchListCount(scope: .allStars, filters: .empty) == 3)
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

    @Test("Repo Pin: 最近置顶优先，组内保留用户排序，取消后恢复")
    func repoPinsPrecedeSelectedSortAndUnpinRestores() async throws {
        let (repo, db) = try makeRepo()
        try await db.insertRepoFixture(id: 1, owner: "octo", name: "one", starredAt: "2026-06-26T03:00:00Z")
        try await db.insertRepoFixture(id: 2, owner: "octo", name: "two", starredAt: "2026-06-26T02:00:00Z")
        try await db.insertRepoFixture(id: 3, owner: "octo", name: "three", starredAt: "2026-06-26T01:00:00Z")

        try await repo.setPinned(repoId: 1, pinnedAt: Date(timeIntervalSince1970: 100))
        try await repo.setPinned(repoId: 3, pinnedAt: Date(timeIntervalSince1970: 200))

        let pinnedPage = try await repo.fetchListPage(
            scope: .allStars,
            filters: .empty,
            sort: .starredAtDesc,
            limit: 2,
            offset: 0
        )
        let pinnedIDs = try await repo.fetchListIDs(
            scope: .allStars,
            filters: .empty,
            sort: .starredAtDesc
        )
        #expect(pinnedPage.map(\.id) == [3, 1], "置顶仓库必须跨分页边界进入首页，且最近置顶在前")
        #expect(pinnedIDs == [3, 1, 2])
        #expect(try await repo.fetchPinnedRepoTimestamps() == [1: 100, 3: 200])
        #expect(try await repo.fetchListCount(scope: .allStars, filters: .empty) == 3)

        try await repo.setPinned(repoId: 3, pinnedAt: nil)
        let afterUnpin = try await repo.fetchListPage(
            scope: .allStars,
            filters: .empty,
            sort: .starredAtDesc,
            limit: 10,
            offset: 0
        )
        #expect(afterUnpin.map(\.id) == [1, 2, 3])
        #expect(try await repo.fetchPinnedRepoTimestamps() == [1: 100])
    }
}
