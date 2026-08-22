//
//  ReadmeAPINetworkTests.swift
//  StarcatTests
//
//  ReadmeAPI 网络路径单测（还 T2.8 延期项 + D-14 配套）。
//
//  覆盖 `refreshReadme(for:) async -> ReadmeRefreshResult` 4 个返回分支：
//  - `.updated(Readme)`     ← 200 → upsert 到本地 + 返回新 Readme
//  - `.notModified(Readme)` ← 304 → touch cached_at + 必要时修复旧 HTML + 返回 Readme
//  - `.notFound`            ← 404 → 删除本地旧缓存 + 返回 notFound
//  - `.failed(Error)`       ← transport / 5xx → 包到 .failed 不抛
//
//  以及 `cachedReadme(for:)` 的本地读路径（命中 / 未命中 / trending→manage promote）。
//
//  设计：
//  - `MockGitHubAPIClient`：实现 `GitHubAPIClientProtocol`，stub `readmeHTML` 返回值（D-02 协议解锁）
//  - `ReadmeRepository`：真接 GRDB 内存库（行为级测试更可信）
//  - `Repo` 测试 fixture：通过 `Self.makeRepoAndDb()` 写入一行 + 返回 repoId
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("ReadmeAPI 网络路径分支")
struct ReadmeAPINetworkTests {

    // MARK: - Fixtures

    /// 构造内存数据库 + 写一个 repo 行（满足 readmes.repo_id 外键）+ ReadmeRepository。
    /// 返回 (api, mock, repo, readmeRepo, db)，调用方按需用。
    private func makeAPI() async throws -> (
        ReadmeAPI,
        MockGitHubAPIClient,
        Repo,
        ReadmeRepository,
        any DatabaseManaging
    ) {
        let db = try InMemoryDatabaseManager()
        let readmeRepo = ReadmeRepository(database: db)
        let repoId: Int64 = 99

        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, description, language,
                    stars_count, forks_count, watchers_count, topics, license,
                    homepage, html_url, clone_url, ssh_url,
                    is_private, is_fork, is_archived, is_starred,
                    pushed_at, created_at, updated_at, starred_at, cached_at
                ) VALUES (
                    ?, 'alice', 'foo', 'alice/foo', 'd', 'Swift',
                    0, 0, 0, '[]', NULL,
                    NULL, 'https://github.com/alice/foo', NULL, NULL,
                    0, 0, 0, 1,
                    NULL, NULL, NULL, NULL, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [repoId]
            )
        }

        // 构造 Repo 实例供 refreshReadme 调用
        let repo = Repo(
            id: repoId,
            owner: "alice",
            name: "foo",
            fullName: "alice/foo",
            description: "d",
            language: "Swift",
            starsCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/alice/foo",
            cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil,
            cachedAt: "2026-05-30T00:00:00Z"
        )

        let mock = MockGitHubAPIClient()
        // W7+：ReadmeAPI 新增 trendingRepository 必填参数，本套测试只验 manage 路径，
        // 用同一个内存库装一个 TrendingReadmeRepository 即可（不会被本套用例触达）。
        let trendingReadmeRepo = TrendingReadmeRepository(database: db)
        // HOM-201 P0-3：ReadmeAPI 新增 inflightTracker 必填参数。本套用例每次都新建
        // 一份 fresh tracker，避免用例之间共享 in-flight 状态。
        let inflightTracker = ReadmeInflightTracker()
        // HOM-201 P2-3:metrics 同款每用例独立 fresh 计数器,避免污染断言。
        let metrics = ReadmeMetrics()
        let api = ReadmeAPI(
            client: mock,
            repository: readmeRepo,
            trendingRepository: trendingReadmeRepo,
            inflightTracker: inflightTracker,
            metrics: metrics
        )
        return (api, mock, repo, readmeRepo, db)
    }

    private func makeReadme(repoId: Int64, html: String, etag: String? = "\"old-etag\"", cachedAt: String = "2026-05-29T00:00:00Z") -> Readme {
        Readme(
            repoId: repoId,
            renderedHtml: html,
            etag: etag,
            lastModified: nil,
            cachedAt: cachedAt,
            size: html.utf8.count
        )
    }

    // MARK: - refreshReadme: 4 个分支

    @Test("refreshReadme: 200 → .updated + 本地 upsert")
    func refresh200Updated() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        let newHTML = "<h1>New README</h1>"

        mock.readmeHTMLHandler = { owner, name, ifNoneMatch, ifModifiedSince in
            #expect(owner == "alice")
            #expect(name == "foo")
            #expect(ifNoneMatch == nil)        // 本地无缓存 → 不带 validator
            #expect(ifModifiedSince == nil)
            return BytesResponse.ok(
                data: newHTML.data(using: .utf8)!,
                etag: "\"new-etag\""
            )
        }

        let result = await api.refreshReadme(for: repo)

        guard case let .updated(updated) = result else {
            Issue.record("期望 .updated，实际: \(result)")
            return
        }
        #expect(updated.renderedHtml == newHTML)
        #expect(updated.etag == "\"new-etag\"")

        // 验证落库
        let cached = try await readmeRepo.find(repoId: repo.id)
        #expect(cached?.renderedHtml == newHTML)
        #expect(cached?.etag == "\"new-etag\"")
    }

    @Test("refreshReadme: 304 + 本地有缓存 → .notModified + cachedAt touch")
    func refresh304NotModified() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        let oldHTML = "<p>Old cached</p>"
        let oldReadme = makeReadme(repoId: repo.id, html: oldHTML, cachedAt: "2026-01-01T00:00:00Z")
        try await readmeRepo.upsert(oldReadme)

        mock.readmeHTMLHandler = { owner, name, ifNoneMatch, _ in
            // 应带上本地 etag 做条件请求
            #expect(ifNoneMatch == "\"old-etag\"")
            return BytesResponse.notModified304(etag: "\"old-etag\"")
        }

        let result = await api.refreshReadme(for: repo)

        guard case let .notModified(touched) = result else {
            Issue.record("期望 .notModified，实际: \(result)")
            return
        }
        // HTML 没变
        #expect(touched.renderedHtml == oldHTML)
        // cachedAt 被 touch（>= 旧值）
        #expect(touched.cachedAt > "2026-01-01T00:00:00Z")

        // 落库也被 touch
        let cached = try await readmeRepo.find(repoId: repo.id)
        #expect(cached?.cachedAt ?? "" > "2026-01-01T00:00:00Z")
    }

    @Test("refreshReadme: 304 命中时修复旧缓存里的 GitHub raw 图片路径")
    func refresh304RepairsCachedRootRawImage() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        let oldHTML = #"<p><img src="/javalin/javalin/raw/master/.github/img/javalin.png" alt="Logo"></p>"#
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: oldHTML))

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.notModified304(etag: "\"old-etag\"")
        }

        let result = await api.refreshReadme(for: repo)
        guard case let .notModified(repaired) = result else {
            Issue.record("期望 .notModified，实际: \(result)")
            return
        }

        let expected = "https://raw.githubusercontent.com/javalin/javalin/master/.github/img/javalin.png"
        #expect(repaired.renderedHtml?.contains(expected) == true)
        #expect(repaired.renderedHtml?.contains(#"/javalin/javalin/raw/master/.github/img/javalin.png"#) == false)

        let cached = try await readmeRepo.find(repoId: repo.id)
        #expect(cached?.renderedHtml?.contains(expected) == true)
    }

    @Test("refreshReadme: 304 命中时修复子目录 README 旧缓存里的错误 raw HEAD 路径")
    func refresh304RepairsCachedSubdirectoryReadmeRawImage() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        let oldHTML = #"""
        <div id="readme" data-path=".github/README.md">
          <img src="https://raw.githubusercontent.com/alice/foo/HEAD/img/javalin.png" alt="Logo">
        </div>
        """#
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: oldHTML))

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.notModified304(etag: "\"old-etag\"")
        }

        let result = await api.refreshReadme(for: repo)
        guard case let .notModified(repaired) = result else {
            Issue.record("期望 .notModified，实际: \(result)")
            return
        }

        let expected = "https://raw.githubusercontent.com/alice/foo/HEAD/.github/img/javalin.png"
        #expect(repaired.renderedHtml?.contains(expected) == true)
        #expect(repaired.renderedHtml?.contains(#"src="https://raw.githubusercontent.com/alice/foo/HEAD/img/javalin.png""#) == false)

        let cached = try await readmeRepo.find(repoId: repo.id)
        #expect(cached?.renderedHtml?.contains(expected) == true)
    }

    @Test("refreshReadme: 304 命中时修复旧缓存里的 GitHub 签名视频地址")
    func refresh304RepairsCachedGitHubVideoURL() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        let oldHTML = #"<video src="https://private-user-images.githubusercontent.com/123/456-3eb63328-0d64-40fd-9a84-f6d08e309d10.webm?jwt=expired" controls="controls">"#
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: oldHTML))

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.notModified304(etag: "\"old-etag\"")
        }

        let result = await api.refreshReadme(for: repo)
        guard case let .notModified(repaired) = result else {
            Issue.record("期望 .notModified，实际: \(result)")
            return
        }

        let expected = "https://github.com/user-attachments/assets/3eb63328-0d64-40fd-9a84-f6d08e309d10"
        #expect(repaired.renderedHtml?.contains(expected) == true)
        #expect(repaired.renderedHtml?.contains("private-user-images.githubusercontent.com") == false)

        let cached = try await readmeRepo.find(repoId: repo.id)
        #expect(cached?.renderedHtml?.contains(expected) == true)
    }

    @Test("refreshReadme: 404 + 本地有旧缓存 → .notFound + 删除旧缓存")
    func refresh404DeletesCache() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: "stale"))

        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.notFound
        }

        let result = await api.refreshReadme(for: repo)

        guard case .notFound = result else {
            Issue.record("期望 .notFound，实际: \(result)")
            return
        }
        // 旧缓存被删
        let cached = try await readmeRepo.find(repoId: repo.id)
        #expect(cached == nil)
    }

    @Test("refreshReadme: 404 + 本地无缓存 → .notFound（无删除噪音）")
    func refresh404NoCache() async throws {
        let (api, mock, repo, _, _) = try await makeAPI()

        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.notFound
        }

        let result = await api.refreshReadme(for: repo)

        guard case .notFound = result else {
            Issue.record("期望 .notFound，实际: \(result)")
            return
        }
    }

    @Test("refreshReadme: transport error → .failed（错误不抛，被包到 .failed）")
    func refreshTransportFailed() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: "old"))

        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.transport(underlying: URLError(.timedOut))
        }

        let result = await api.refreshReadme(for: repo)

        guard case let .failed(error) = result else {
            Issue.record("期望 .failed，实际: \(result)")
            return
        }
        // 包的是 transport
        if case NetworkError.transport = error {
            // 通过
        } else {
            Issue.record("期望 .failed 包 NetworkError.transport，实际: \(error)")
        }

        // SWR 关键：失败时旧缓存保留（refreshReadme 不删）
        let cached = try await readmeRepo.find(repoId: repo.id)
        #expect(cached?.renderedHtml == "old", "失败时旧缓存必须保留，让上层 SWR 兜底显示")
    }

    @Test("refreshReadme: 5xx → .failed（serverError 包到 .failed）")
    func refresh500Failed() async throws {
        let (api, mock, repo, _, _) = try await makeAPI()

        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.serverError(statusCode: 502)
        }

        let result = await api.refreshReadme(for: repo)
        guard case let .failed(error) = result else {
            Issue.record("期望 .failed，实际: \(result)")
            return
        }
        if case NetworkError.serverError(let code) = error {
            #expect(code == 502)
        } else {
            Issue.record("期望 .failed 包 serverError，实际: \(error)")
        }
    }

    // MARK: - cachedReadme（纯本地读路径）

    @Test("cachedReadme: 本地命中 → 返回 Readme")
    func cachedHit() async throws {
        let (api, _, repo, readmeRepo, _) = try await makeAPI()
        let readme = makeReadme(repoId: repo.id, html: "local")
        try await readmeRepo.upsert(readme)

        let cached = try await api.cachedReadme(for: repo)
        #expect(cached?.renderedHtml == "local")
    }

    @Test("cachedReadme: 本地命中时修复子目录 README 旧缓存里的错误 raw HEAD 路径")
    func cachedHitRepairsSubdirectoryReadmeRawImage() async throws {
        let (api, _, repo, readmeRepo, _) = try await makeAPI()
        let oldHTML = #"""
        <div id="readme" data-path=".github/README.md">
          <img src="https://raw.githubusercontent.com/alice/foo/HEAD/img/javalin.png" alt="Logo">
        </div>
        """#
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: oldHTML))

        let cached = try await api.cachedReadme(for: repo)

        let expected = "https://raw.githubusercontent.com/alice/foo/HEAD/.github/img/javalin.png"
        #expect(cached?.renderedHtml?.contains(expected) == true)
        #expect(cached?.renderedHtml?.contains(#"src="https://raw.githubusercontent.com/alice/foo/HEAD/img/javalin.png""#) == false)

        let persisted = try await readmeRepo.find(repoId: repo.id)
        #expect(persisted?.renderedHtml?.contains(expected) == true)
    }

    @Test("cachedReadme: 本地命中时修复并持久化 GitHub 签名视频地址")
    func cachedHitRepairsGitHubVideoURL() async throws {
        let (api, _, repo, readmeRepo, _) = try await makeAPI()
        let oldHTML = #"<video src="https://private-user-images.githubusercontent.com/123/456-3eb63328-0d64-40fd-9a84-f6d08e309d10.webm?jwt=expired" controls="controls">"#
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: oldHTML))

        let cached = try await api.cachedReadme(for: repo)

        let expected = "https://github.com/user-attachments/assets/3eb63328-0d64-40fd-9a84-f6d08e309d10"
        #expect(cached?.renderedHtml?.contains(expected) == true)
        #expect(cached?.renderedHtml?.contains("jwt=expired") == false)

        let persisted = try await readmeRepo.find(repoId: repo.id)
        #expect(persisted?.renderedHtml?.contains(expected) == true)
        #expect(persisted?.renderedHtml?.contains("jwt=expired") == false)
    }

    @Test("cachedReadme: 本地未命中 → 返回 nil")
    func cachedMiss() async throws {
        let (api, _, repo, _, _) = try await makeAPI()

        let cached = try await api.cachedReadme(for: repo)
        #expect(cached == nil)
    }

    // MARK: - HOM-201 P0-1: trending → manage cache promote

    @Test("cachedReadme: manage miss + trending hit → promote 到 manage 表 + 清 trending 行")
    func cachedTrendingPromote() async throws {
        let (api, _, repo, readmeRepo, db) = try await makeAPI()
        let trendingRepo = TrendingReadmeRepository(database: db)

        // 准备：trending_readmes 里有这个 repo 的 README，manage 表没有
        let trendingRecord = TrendingReadme(
            fullName: repo.fullName,
            renderedHtml: "trending-html",
            etag: "\"trend-etag\"",
            lastModified: nil,
            cachedAt: "2026-06-14T00:00:00Z",
            size: 13
        )
        try await trendingRepo.upsert(trendingRecord)

        // 第一次调用：manage miss → trending hit → promote
        let cached = try await api.cachedReadme(for: repo)
        #expect(cached?.renderedHtml == "trending-html")
        #expect(cached?.etag == "\"trend-etag\"")
        #expect(cached?.repoId == repo.id)

        // promote 成功后 manage 表应有这行
        let manageRow = try await readmeRepo.find(repoId: repo.id)
        #expect(manageRow?.renderedHtml == "trending-html")
        #expect(manageRow?.etag == "\"trend-etag\"")

        // trending 行应被清掉，避免双份存储
        let trendingRow = try await trendingRepo.find(fullName: repo.fullName)
        #expect(trendingRow == nil)
    }

    @Test("cachedReadme: trending promote 前修复子目录 README 图片路径")
    func cachedTrendingPromoteRepairsSubdirectoryReadmeRawImage() async throws {
        let (api, _, repo, readmeRepo, db) = try await makeAPI()
        let trendingRepo = TrendingReadmeRepository(database: db)
        let oldHTML = #"""
        <div id="readme" data-path=".github/README.md">
          <img src="https://raw.githubusercontent.com/alice/foo/HEAD/img/javalin.png" alt="Logo">
        </div>
        """#
        try await trendingRepo.upsert(TrendingReadme(
            fullName: repo.fullName,
            renderedHtml: oldHTML,
            etag: "\"trend-etag\"",
            lastModified: nil,
            cachedAt: "2026-06-14T00:00:00Z",
            size: oldHTML.utf8.count
        ))

        let cached = try await api.cachedReadme(for: repo)

        let expected = "https://raw.githubusercontent.com/alice/foo/HEAD/.github/img/javalin.png"
        #expect(cached?.renderedHtml?.contains(expected) == true)
        #expect(cached?.renderedHtml?.contains(#"src="https://raw.githubusercontent.com/alice/foo/HEAD/img/javalin.png""#) == false)

        let manageRow = try await readmeRepo.find(repoId: repo.id)
        #expect(manageRow?.renderedHtml?.contains(expected) == true)
    }

    @Test("cachedReadme: manage hit 直接返回，不查 trending")
    func cachedManageHitSkipsTrending() async throws {
        let (api, _, repo, readmeRepo, db) = try await makeAPI()
        let trendingRepo = TrendingReadmeRepository(database: db)

        // 两表都有数据；manage 应优先返回
        let manage = makeReadme(repoId: repo.id, html: "manage-html")
        try await readmeRepo.upsert(manage)
        try await trendingRepo.upsert(TrendingReadme(
            fullName: repo.fullName,
            renderedHtml: "trending-html",
            etag: nil,
            lastModified: nil,
            cachedAt: "2026-06-14T00:00:00Z",
            size: 14
        ))

        let cached = try await api.cachedReadme(for: repo)
        #expect(cached?.renderedHtml == "manage-html")

        // trending 行未被动到（cachedReadme manage 命中后短路）
        let trendingRow = try await trendingRepo.find(fullName: repo.fullName)
        #expect(trendingRow != nil)
    }

    // MARK: - HOM-201 P1-1: prefetch（列表 hover 预拉）

    /// 关键路径：缓存在 6h 内 → 完全短路网络（GitHub 配额保护）。
    @Test("prefetch: cache 在 softTtl 内 → 不调用 GitHub")
    func prefetchSkipsWhenFresh() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()

        // 写一条 cachedAt 是"刚才"的本地缓存
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: "fresh", cachedAt: nowISO))

        await api.prefetch(for: repo)

        #expect(mock.readmeHTMLCalls.isEmpty)
    }

    /// 缓存过期 → prefetch 应触发条件刷新（被 inflight tracker 自动 dedupe）。
    @Test("prefetch: cache 过期 → 走 refreshReadme")
    func prefetchTriggersRefreshWhenStale() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()

        // 过去 24h 远超 softTtl=6h
        let stale = ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-24 * 3600))
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: "stale", cachedAt: stale))

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("<h1>new</h1>".utf8), etag: "\"new\"")
        }

        await api.prefetch(for: repo)

        #expect(mock.readmeHTMLCalls.count == 1)
        let refreshed = try await readmeRepo.find(repoId: repo.id)
        #expect(refreshed?.renderedHtml == "<h1>new</h1>")
    }

    /// 无缓存 → 必须刷一次。
    @Test("prefetch: 无 cache → 走 refreshReadme")
    func prefetchTriggersRefreshWhenMissing() async throws {
        let (api, mock, repo, _, _) = try await makeAPI()

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("<h1>fresh</h1>".utf8), etag: "\"e\"")
        }

        await api.prefetch(for: repo)

        #expect(mock.readmeHTMLCalls.count == 1)
    }

    /// 入库 RAG 补齐和后台预拉都会调用这两个 API；请求尚未完成时必须复用同一 in-flight Task。
    @Test("同仓库并发补齐 README 时 HTML 与 Markdown 各只请求一次")
    func concurrentReadmeCompletionDeduplicatesBothRequests() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()

        mock.readmeHTMLHandler = { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return BytesResponse.ok(data: Data("<h1>README</h1>".utf8), etag: "\"html\"")
        }

        async let firstHTML = api.refreshReadme(for: repo)
        async let secondHTML = api.refreshReadme(for: repo)
        _ = await (firstHTML, secondHTML)

        #expect(mock.readmeHTMLCalls.count == 1)
        #expect(try await readmeRepo.find(repoId: repo.id) != nil)

        mock.readmeMarkdownHandler = { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return BytesResponse.ok(data: Data("# README".utf8), etag: "\"markdown\"")
        }

        async let firstMarkdown = api.refreshMarkdownIfNeeded(for: repo)
        async let secondMarkdown = api.refreshMarkdownIfNeeded(for: repo)
        _ = await (firstMarkdown, secondMarkdown)

        #expect(mock.readmeMarkdownCalls.count == 1)
        #expect(try await readmeRepo.findContent(repoId: repo.id) == "# README")
    }

    /// trending prefetch: 同上 softTtl 短路语义。
    @Test("prefetchTrending: cache 在 softTtl 内 → 不调用 GitHub")
    func prefetchTrendingSkipsWhenFresh() async throws {
        let (api, mock, _, _, db) = try await makeAPI()
        let trendingRepo = TrendingReadmeRepository(database: db)

        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await trendingRepo.upsert(TrendingReadme(
            fullName: "octocat/hello",
            renderedHtml: "fresh",
            etag: nil,
            lastModified: nil,
            cachedAt: nowISO,
            size: 5
        ))

        await api.prefetchTrending(owner: "octocat", repo: "hello")

        #expect(mock.readmeHTMLCalls.isEmpty)
    }

    // MARK: - HOM-201 P1-2: rewrite-at-upsert（rendered_html 落库前先 rewrite img）

    /// refreshReadme 200 分支:落库的 rendered_html 应该是 rewrite 过的(img 已是 raw URL)。
    @Test("refreshReadme: 200 写库前 img 相对路径 rewrite 为 raw.githubusercontent.com")
    func refresh200RewritesImg() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        let rawHTML = #"<p>logo:<img src="./logo.png" alt="x"></p>"#

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: rawHTML.data(using: .utf8)!, etag: "\"e\"")
        }

        let result = await api.refreshReadme(for: repo)
        guard case let .updated(updated) = result else {
            Issue.record("期望 .updated，实际: \(result)")
            return
        }

        // 落到 Readme 对象与 DB 行的 rendered_html 都应是 rewrite 后版本
        let expectedRewritten = "https://raw.githubusercontent.com/\(repo.owner)/\(repo.name)/HEAD/logo.png"
        #expect(updated.renderedHtml?.contains(expectedRewritten) == true)
        #expect(updated.renderedHtml?.contains("./logo.png") == false)

        let fetched = try await readmeRepo.find(repoId: repo.id)
        #expect(fetched?.renderedHtml?.contains(expectedRewritten) == true)
        #expect(fetched?.renderedHtml?.contains("./logo.png") == false)
    }

    /// refreshTrendingReadme 200 分支同款 rewrite 校验。
    @Test("refreshTrendingReadme: 200 写库前 img 相对路径 rewrite 为 raw.githubusercontent.com")
    func refreshTrending200RewritesImg() async throws {
        let (api, mock, _, _, db) = try await makeAPI()
        let trendingRepo = TrendingReadmeRepository(database: db)
        let rawHTML = #"<p>logo:<img src="./logo.png" alt="x"></p>"#

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: rawHTML.data(using: .utf8)!, etag: "\"e\"")
        }

        let result = await api.refreshTrendingReadme(owner: "octocat", repo: "hello")
        guard case .updated = result else {
            Issue.record("期望 .updated，实际: \(result)")
            return
        }

        let fetched = try await trendingRepo.find(fullName: "octocat/hello")
        let expectedRewritten = "https://raw.githubusercontent.com/octocat/hello/HEAD/logo.png"
        #expect(fetched?.renderedHtml?.contains(expectedRewritten) == true)
        #expect(fetched?.renderedHtml?.contains("./logo.png") == false)
    }

    @Test("refreshTrendingReadme: 304 命中时修复旧缓存里的 GitHub raw 图片路径")
    func refreshTrending304RepairsCachedRootRawImage() async throws {
        let (api, mock, _, _, db) = try await makeAPI()
        let trendingRepo = TrendingReadmeRepository(database: db)
        let oldHTML = #"<img src="/javalin/javalin/raw/master/.github/img/javalin.png" alt="Logo">"#
        try await trendingRepo.upsert(TrendingReadme(
            fullName: "javalin/javalin",
            renderedHtml: oldHTML,
            etag: "\"old-etag\"",
            lastModified: nil,
            cachedAt: "2026-01-01T00:00:00Z",
            size: oldHTML.utf8.count
        ))

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.notModified304(etag: "\"old-etag\"")
        }

        let result = await api.refreshTrendingReadme(owner: "javalin", repo: "javalin")
        guard case .updated = result else {
            Issue.record("期望 .updated，实际: \(result)")
            return
        }

        let expected = "https://raw.githubusercontent.com/javalin/javalin/master/.github/img/javalin.png"
        let fetched = try await trendingRepo.find(fullName: "javalin/javalin")
        #expect(fetched?.renderedHtml?.contains(expected) == true)
        #expect(fetched?.renderedHtml?.contains(#"/javalin/javalin/raw/master/.github/img/javalin.png"#) == false)
    }

    @Test("prefetchTrending: cache 过期 → 走 refreshTrendingReadme")
    func prefetchTrendingTriggersRefreshWhenStale() async throws {
        let (api, mock, _, _, db) = try await makeAPI()
        let trendingRepo = TrendingReadmeRepository(database: db)

        let stale = ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-24 * 3600))
        try await trendingRepo.upsert(TrendingReadme(
            fullName: "octocat/hello",
            renderedHtml: "stale",
            etag: nil,
            lastModified: nil,
            cachedAt: stale,
            size: 5
        ))

        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("<h1>new</h1>".utf8), etag: "\"new\"")
        }

        await api.prefetchTrending(owner: "octocat", repo: "hello")

        #expect(mock.readmeHTMLCalls.count == 1)
    }

    @Test("同仓 Markdown: Contents HTML 进会话缓存且不写 readmes 表")
    func fetchRenderedRepositoryMarkdownUsesSessionCacheOnly() async throws {
        let (api, mock, repo, readmeRepo, _) = try await makeAPI()
        let cache = RepositoryMarkdownSessionCache()

        mock.repositoryFileHTMLHandler = { owner, name, path, ref, _ in
            #expect(owner == "alice")
            #expect(name == "foo")
            #expect(path == "README.zh-CN.md")
            #expect(ref == "HEAD")
            return BytesResponse.ok(data: Data("<h1>中文</h1>".utf8), etag: "\"zh\"")
        }

        let html = try await api.fetchRenderedRepositoryMarkdown(
            owner: repo.owner,
            repo: repo.name,
            path: "README.zh-CN.md",
            ref: "HEAD",
            cache: cache
        )
        #expect(html.contains("中文"))
        #expect(try await readmeRepo.find(repoId: repo.id) == nil)

        mock.repositoryFileHTMLHandler = { _, _, _, _, _ in
            Issue.record("session cache should skip the second network call")
            return BytesResponse.ok(data: Data("<h1>should-not-fetch</h1>".utf8), etag: "\"x\"")
        }

        let cached = try await api.fetchRenderedRepositoryMarkdown(
            owner: repo.owner,
            repo: repo.name,
            path: "README.zh-CN.md",
            ref: "HEAD",
            cache: cache
        )
        #expect(cached.contains("中文"))
    }
}
