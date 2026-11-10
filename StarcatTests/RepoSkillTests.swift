//
//  RepoSkillTests.swift
//  StarcatTests
//
//  Skill 真实链路回归：识别证据、分页前 SQL 筛选、完整目录发布与失败保护。
//  安装全部使用独立临时目录，不写用户的 Agent 目录。
//

import Foundation
import GRDB
import SwiftUI
import Synchronization
import Testing
@testable import Starcat

@Suite("Repository Skills")
struct RepoSkillTests {
    private func repo() async throws -> Repo {
        let db = try InMemoryDatabaseManager()
        try await db.insertRepoFixture(id: 1)
        return try #require(try await GRDBRepoRepository(database: db).findById(1))
    }

    @Test("frontmatter 支持引号、折叠、根目录；拒绝无效名称、重复字段与目录不符")
    func frontmatter() throws {
        let folded = """
        ---
        name: review
        description: >
          Review repositories
          with references.
        metadata:
          author: example
        ---
        # Example
        """
        #expect(try SkillFrontmatter.parse(folded, directory: "skills/review/").description == "Review repositories with references.")
        #expect(try SkillFrontmatter.parse("---\nname: 'review'\ndescription: \"A: B\"\n---", directory: "").name == "review")
        for value in [
            "# SKILL.md\nname: review", "---\nname: ../review\ndescription: text\n---",
            "---\nname: review\nname: another\ndescription: text\n---",
            "---\nname: review\ndescription: [nested]\n---"
        ] {
            #expect(throws: (any Error).self) { try SkillFrontmatter.parse(value, directory: "") }
        }
        #expect(throws: (any Error).self) { try SkillFrontmatter.parse(folded, directory: "skills/other/") }
        #expect(SkillFrontmatter.isValidName("révision"))
        #expect(!SkillFrontmatter.isValidName("Review"))
        #expect(SkillFrontmatter.stripFrontmatter(folded) == "# Example")
        #expect(SkillFrontmatter.stripFrontmatter("---\nname: 'review'\ndescription: \"A: B\"\n---") == "")
        #expect(SkillFrontmatter.stripFrontmatter("# Plain document") == "# Plain document")
        #expect(RepoSkillScanner.hasReferencesOutsideDirectory("[guide](../shared/guide.md)", directory: "skills/review/"))
        #expect(!RepoSkillScanner.hasReferencesOutsideDirectory("[guide](./references/guide.md)", directory: "skills/review/"))
    }

    @Test("扫描固定提交并保留附属文件，重名不同路径不合并")
    func scanner() async throws {
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, path, ref in
            #expect(path.isEmpty && ref == "HEAD")
            return GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, ref in
            #expect(ref == "fixed")
            return GitHubGitTreeDTO(sha: "tree", truncated: false, tree: [
                skillEntry("one/review/SKILL.md", sha: "manifest"),
                skillEntry("one/review/scripts/check.sh", sha: "script", mode: "100755"),
                skillEntry("two/review/SKILL.md", sha: "manifest")
            ])
        }
        let scanner = RepoSkillScanner(
            api: api, downloader: SkillTestDownloader(), cache: RepoFileTreeSessionCache(), cacheScope: "test"
        )
        let result = try await scanner.scan(try await repo())
        #expect(result.complete && result.presence == .contains)
        #expect(result.skills.count == 2)
        #expect(Set(result.skills.map(\.id)).count == 2)
        #expect(result.skills[0].files.map(\.path) == ["SKILL.md", "scripts/check.sh"])
        #expect(result.skills[0].commitSHA == "fixed")
        // 预览只保留正文，frontmatter 不进 Markdown 渲染。
        #expect(result.skills[0].manifest == "# Review")
    }

    @Test("树截断补查失败仍保留已核实 Skill，零证据不判为不存在")
    func partialScanner() async throws {
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: true, tree: [skillEntry("review/SKILL.md", sha: "manifest")])
        }
        let scanner = RepoSkillScanner(
            api: api, downloader: SkillTestDownloader(), cache: RepoFileTreeSessionCache(), cacheScope: "test"
        )
        let scan = try await scanner.scan(try await repo())
        #expect(!scan.complete && scan.presence == .contains && scan.skills.count == 1)
        api.repositoryGitTreeHandler = { _, _, _ in GitHubGitTreeDTO(sha: "other", truncated: true, tree: []) }
        let empty = try await RepoSkillScanner(
            api: api, downloader: SkillTestDownloader(), cache: RepoFileTreeSessionCache(), cacheScope: "other"
        ).scan(try await repo())
        #expect(!empty.complete && empty.presence == .unknown)
    }

    @Test("首个有效 Skill 先发布，集合继续补齐且安装清单保持未完成")
    func incrementalScanner() async throws {
        let paths = ["skills/one/SKILL.md", "skills/two/SKILL.md", "skills/three/SKILL.md"]
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: paths.map { skillEntry($0, sha: "sha-\($0)") })
        }
        let snapshotCounts = Mutex<[Int]>([])
        let scan = try await RepoSkillScanner(
            api: api,
            downloader: ManifestTestDownloader(paths: paths),
            cache: RepoFileTreeSessionCache(),
            cacheScope: "incremental"
        ).scan(try await repo(), manifestConcurrency: 1) { partial in
            #expect(!partial.complete)
            snapshotCounts.withLock { $0.append(partial.skills.count) }
        }
        let observedCounts = snapshotCounts.withLock { $0 }
        #expect(scan.complete && scan.skills.count == 3)
        #expect(scan.manifestTotal == 3 && scan.manifestChecked == 3)
    }

    @Test("manifest 小并发读取；单个无效候选不吞掉同批有效 Skill")
    func concurrentManifestsKeepPartialEvidence() async throws {
        let paths = (1...6).map { "skills/skill-\($0)/SKILL.md" }
        let broken = "skills/skill-3/SKILL.md"
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: paths.map { skillEntry($0, sha: "sha-\($0)") })
        }
        let downloader = ManifestTestDownloader(paths: paths, invalidPath: broken, delay: .milliseconds(25))
        let scan = try await RepoSkillScanner(
            api: api, downloader: downloader, cache: RepoFileTreeSessionCache(), cacheScope: "concurrent"
        ).scan(try await repo())
        #expect(scan.presence == .contains && scan.skills.count == 5)
        #expect(scan.diagnostics.count == 1 && scan.diagnostics[0].contains(broken))
        let stats = downloader.statistics
        #expect(stats.previewCount == 6 && stats.maxActive >= 2 && stats.maxActive <= 4)
    }

    @Test("完整目录安装、执行位、安装记录与本地修改冲突")
    func installAndInspect() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = installSkill()
        let installer = RepoSkillInstaller(downloader: SkillTestDownloader())
        let source = try await repo()
        let destination = RepoSkillDestination(preset: .agents, url: root)
        #expect(try await installer.existing(skill, destination: destination) == .missing)
        try await installer.install(skill, repo: source, destination: destination, replacing: false, onProgress: { _ in })
        #expect(try await installer.existing(skill, destination: destination) == .installed)
        // 预设只影响 UI 文案；核对身份来自实际目录，不同目录彼此独立。
        let claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        #expect(try await installer.existing(
            skill, destination: RepoSkillDestination(preset: .claudeCode, url: claudeRoot)
        ) == .missing)
        let script = root.appendingPathComponent("review/scripts/check.sh")
        let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        #expect((mode?.intValue ?? 0) & 0o111 != 0)
        try Data("local edit".utf8).write(to: script)
        #expect(try await installer.existing(skill, destination: destination) == .conflict)
        await #expect(throws: (any Error).self) {
            try await installer.install(skill, repo: source, destination: destination, replacing: false, onProgress: { _ in })
        }
        #expect(try String(contentsOf: script, encoding: .utf8) == "local edit")
        let broken = RepoSkillInstaller(downloader: SkillTestDownloader(failing: true))
        await #expect(throws: (any Error).self) {
            try await broken.install(skill, repo: source, destination: destination, replacing: true, onProgress: { _ in })
        }
        #expect(try String(contentsOf: script, encoding: .utf8) == "local edit")
        try await installer.install(skill, repo: source, destination: destination, replacing: true, onProgress: { _ in })
        #expect(try await installer.existing(skill, destination: destination) == .installed)
        try Data("extra".utf8).write(to: root.appendingPathComponent("review/extra.txt"))
        #expect(try await installer.existing(skill, destination: destination) == .conflict)
    }

    @Test("下载失败与取消不留下半成品或覆盖旧内容")
    func installationFailureAndCancellation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await repo()
        let skill = installSkill()
        let destination = RepoSkillDestination(preset: .agents, url: root)
        let broken = RepoSkillInstaller(downloader: SkillTestDownloader(failing: true))
        await #expect(throws: (any Error).self) {
            try await broken.install(skill, repo: source, destination: destination, replacing: false, onProgress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("review").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let task = Task {
            try await RepoSkillInstaller(downloader: SkillTestDownloader(delay: .seconds(2)))
                .install(skill, repo: source, destination: destination, replacing: false, onProgress: { _ in })
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("review").path))
    }

    @Test("工具目录可为符号链接，文件枚举仍正确核对相对路径")
    func installationAtLinkedRoot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let installer = RepoSkillInstaller(downloader: SkillTestDownloader())
        let source = try await repo()
        let skill = installSkill()
        try await installer.install(skill, repo: source, destination: RepoSkillDestination(preset: .agents, url: alias),
                                    replacing: false, onProgress: { _ in })
        #expect(try await installer.existing(skill, destination: RepoSkillDestination(preset: .agents, url: alias)) == .installed)
        #expect(try await installer.existing(skill, destination: RepoSkillDestination(preset: .agents, url: actual)) == .installed)
    }

    @MainActor
    @Test("多目录会话按目录独立核对，全部目录完成才算已安装")
    func multiDestinationSession() async throws {
        let db = try InMemoryDatabaseManager()
        let api = MockGitHubAPIClient()
        let manifestSHA = RepoFileDownloader.gitBlobSHA(Data("SKILL.md".utf8))
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: [skillEntry("SKILL.md", sha: manifestSHA)])
        }
        let source = try await repo()
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                  publicDownloader: SkillTestDownloader(), privateDownloader: SkillTestDownloader())
        _ = try await store.detect(source)

        let rootA = temporaryRoot()
        let rootB = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let defaults = try #require(UserDefaults(suiteName: "skills-multi-\(UUID().uuidString)"))
        let session = RepoSkillSession(
            repo: source, store: store,
            destinations: [
                RepoSkillDestination(preset: .agents, url: rootA),
                RepoSkillDestination(preset: .claudeCode, url: rootB)
            ],
            defaults: defaults
        )
        await session.load()
        let skill = try #require(session.skills.first)
        session.selectAllDestinations(true)
        session.selectAll(true)
        #expect(session.installedIDs.isEmpty)
        #expect(session.coverage(of: skill.id) == 0)
        #expect(session.plannedItems.count == 2)

        // 勾选目录会触发异步复核；按钮与 UI 同样等待复核完成后才允许开始。
        var waited = 0
        while session.isCheckingDestination && waited < 400 { try await Task.sleep(for: .milliseconds(25)); waited += 1 }
        #expect(!session.isCheckingDestination)
        session.start()
        waited = 0
        while session.isInstalling && waited < 400 { try await Task.sleep(for: .milliseconds(25)); waited += 1 }
        #expect(session.phase == .finished && !session.hasFailures)
        #expect(session.installedIDs.contains(skill.id))
        #expect(session.coverage(of: skill.id) == 2)

        // 一个目录被本地修改后只影响该目录，Skill 重新回到未安装口径。
        try Data("extra".utf8).write(to: rootB.appendingPathComponent("review/extra.txt"))
        await session.refreshDestination()
        #expect(!session.installedIDs.contains(skill.id))
        #expect(session.coverage(of: skill.id) == 1)
        session.close()
    }

    @Test("v24 升级追加 v25，SQL 在分页/COUNT/ID 查询前筛选并排除过期证据")
    func migrationAndSQL() async throws {
        let queue = try DatabaseQueue()
        var migrations = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrations)
        try migrations.migrate(queue, upTo: "v24-github-star-list-local-overrides")
        #expect(try await queue.read { try !$0.tableExists("repo_skill_scans") })
        try migrations.migrate(queue)
        #expect(try await queue.read { try $0.tableExists("repo_skill_scans") })
        let db = try InMemoryDatabaseManager()
        let repository = GRDBRepoRepository(database: db)
        for id in Int64(1)...Int64(6) { try await db.insertRepoFixture(id: id) }
        try await db.writer.write { db in
            for (id, presence, expires) in [(Int64(1), "contains", 4_000_000_000.0), (2, "contains", 4_000_000_000),
                                          (3, "absent", 4_000_000_000), (4, "unknown", 4_000_000_000),
                                          (5, "absent", 0)] {
                try db.execute(sql: """
                    INSERT INTO repo_skill_scans
                    (repo_id, commit_sha, rules_version, expires_at, presence, payload)
                    VALUES (?, 'fixed', \(RepoSkillScan.rulesVersion), ?, ?, X'00')
                    """, arguments: [id, expires, presence])
            }
        }
        var filters = RepoListFilters(hideArchived: false, hideForks: false, status: nil, skill: .contains, selectedTagIDs: [])
        #expect(try await repository.fetchListCount(scope: .allStars, filters: filters) == 2)
        let page = try await repository.fetchListPage(scope: .allStars, filters: filters, sort: .nameAsc, limit: 1, offset: 1)
        #expect(page.map(\.id) == [2])
        filters.skill = .unknown
        #expect(try await repository.fetchListIDs(scope: .allStars, filters: filters, sort: .nameAsc) == [4, 5, 6])
        filters.skill = .absent
        #expect(try await repository.fetchListCount(scope: .allStars, filters: filters) == 1)
        try await db.writer.write { try $0.execute(sql: "UPDATE repos SET pushed_at = 'changed' WHERE id = 3") }
        #expect(try await repository.fetchListCount(scope: .allStars, filters: filters) == 0)
    }

    @Test("远端空命中补页预算跨任务累计，切范围重置")
    func pageBudget() {
        var budget = RepoSkillPageBudget()
        for _ in 0..<20 {
            let claimed = budget.claim(scope: "a")
            #expect(claimed)
        }
        let exhausted = budget.claim(scope: "a")
        #expect(!exhausted)
        let changedScope = budget.claim(scope: "b")
        #expect(changedScope)
    }

    @Test("重建完整截断树；预算耗尽只保留部分证据")
    func recoveredTree() async throws {
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in GitHubGitTreeDTO(sha: "root", truncated: true, tree: []) }
        api.repositoryGitTreeLevelHandler = { _, _, ref in
            if ref == "root" {
                return GitHubGitTreeDTO(sha: "root", truncated: false, tree: [
                    GitHubGitTreeEntryDTO(path: "review", mode: "040000", type: "tree", sha: "child", size: nil, url: nil)
                ])
            }
            return GitHubGitTreeDTO(sha: "child", truncated: false, tree: [
                skillEntry("SKILL.md", sha: "manifest"), skillEntry("guide.md", sha: "guide")
            ])
        }
        let scanner = RepoSkillScanner(api: api, downloader: SkillTestDownloader(),
                                       cache: RepoFileTreeSessionCache(), cacheScope: "recovered")
        let source = try await repo()
        let recovered = try await scanner.scan(source)
        #expect(recovered.complete && recovered.skills.first?.files.count == 2)
        let partial = try await scanner.scan(source, treeBudget: 1)
        #expect(!partial.complete && partial.presence == .unknown)
    }

    @Test("文件树隔离凭据客户端，切账号后拒绝迟到的旧请求")
    func treeCacheScope() async throws {
        let cache = RepoFileTreeSessionCache()
        let api = MockGitHubAPIClient()
        api.repositoryGitTreeHandler = { _, _, _ in GitHubGitTreeDTO(sha: "public", truncated: false, tree: []) }
        _ = try await cache.load(owner: "o", repo: "r", ref: "commit", scope: "public", api: api)
        api.repositoryGitTreeHandler = { _, _, _ in GitHubGitTreeDTO(sha: "private", truncated: false, tree: []) }
        let isolated = try await cache.load(owner: "o", repo: "r", ref: "commit", scope: "private", api: api)
        #expect(isolated.sha == "private")
        let generation = await cache.currentGeneration()
        await cache.reset()
        await #expect(throws: CancellationError.self) {
            try await cache.load(owner: "o", repo: "r", ref: "commit", scope: "private", api: api,
                                 expectedGeneration: generation)
        }
    }

    @MainActor
    @Test("扫描摘要可恢复；账号切换清空证据并等待安装取消")
    func persistenceAndAccountBarrier() async throws {
        let db = try InMemoryDatabaseManager()
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: [skillEntry("SKILL.md", sha: "manifest")])
        }
        let source = try await repo()
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                  publicDownloader: SkillTestDownloader(), privateDownloader: SkillTestDownloader())
        _ = try await store.detect(source)
        let restored = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                     publicDownloader: SkillTestDownloader(), privateDownloader: SkillTestDownloader())
        await restored.prepare()
        #expect(restored.presence(for: source) == .contains)
        var changed = source
        changed.pushedAt = "2026-11-10T00:00:00Z"
        restored.togglePause()
        restored.enqueue([changed], scope: "updated")
        #expect(restored.presence(repositoryID: source.id) == .unknown)
        let cleaned = Mutex(false)
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            cleaned.withLock { $0 = true }
        }
        restored.trackInstallation(task, id: UUID())
        await restored.resetForAccountChange()
        #expect(cleaned.withLock { $0 })
        #expect(restored.scans.isEmpty && restored.isChangingAccount)
        try await db.reopen(userId: 42)
        restored.finishAccountChange()
        await restored.prepare()
        #expect(restored.presence(for: source) == .unknown)
    }

    @MainActor
    @Test("详情在扫描中接收部分 Skill，最终快照替换为完整证据")
    func storePublishesPartialScan() async throws {
        let db = try InMemoryDatabaseManager()
        let api = MockGitHubAPIClient()
        let paths = (1...5).map { "skills/skill-\($0)/SKILL.md" }
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            // 同一测试类共享 Git tree 进程缓存；使用独立 commit 避免读到前置用例的单 Skill 树。
            GitHubCommitSummaryDTO(sha: "store-partial-fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: paths.map { skillEntry($0, sha: "sha-\($0)") })
        }
        let source = try await repo()
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                   publicDownloader: ManifestTestDownloader(paths: paths),
                                   privateDownloader: ManifestTestDownloader(paths: paths))
        let partialCounts = Mutex<[Int]>([])
        let final = try await store.detect(source) { partial in
            #expect(!partial.complete)
            #expect(store.presence(for: source) == .contains)
            #expect(store.scanningIDs.contains(source.id))
            partialCounts.withLock { $0.append(partial.skills.count) }
        }
        let observedPartialCounts = partialCounts.withLock { $0 }
        #expect(!observedPartialCounts.isEmpty)
        #expect(final.complete && final.skills.count == 5)
        #expect(store.presence(for: source) == .contains && !store.scanningIDs.contains(source.id))
    }

    @MainActor
    @Test("后台候选去重并限定每批 200；切范围丢弃旧队列")
    func boundedQueue() async throws {
        let db = try InMemoryDatabaseManager()
        let api = MockGitHubAPIClient()
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                  publicDownloader: SkillTestDownloader(), privateDownloader: SkillTestDownloader())
        store.togglePause()
        let source = try await repo()
        let candidates = (1...250).map { id in
            var candidate = source
            candidate.id = Int64(id)
            return candidate
        }
        store.enqueue(candidates + candidates, scope: "a")
        #expect(store.candidateCount == 250 && store.remainingCount == 200)
        store.enqueue(candidates, scope: "a")
        #expect(store.remainingCount == 200)
        store.enqueue([source, source], scope: "b")
        #expect(store.candidateCount == 1 && store.remainingCount == 1)
        await store.resetForAccountChange()
    }
}

@Suite("Skill 列表行视觉状态")
struct RepoSkillRowChromeTests {
    @Test("斑马纹、悬停与选中使用规范中的固定优先级")
    func rowBackgroundPrecedence() {
        #expect(RepoSkillRowChrome.background(rowIndex: 1, isSelected: false, isHovered: false) == Color.primary.opacity(0.045))
        #expect(RepoSkillRowChrome.background(rowIndex: 1, isSelected: false, isHovered: true) == Color.accentColor.opacity(0.08))
        #expect(RepoSkillRowChrome.background(rowIndex: 0, isSelected: true, isHovered: true) == Color.accentColor.opacity(0.14))
    }
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("starcat-skill-test-\(UUID().uuidString)")
}

private func skillEntry(_ path: String, sha: String, mode: String = "100644") -> GitHubGitTreeEntryDTO {
    GitHubGitTreeEntryDTO(path: path, mode: mode, type: "blob", sha: sha, size: nil, url: nil)
}

/// 按路径返回合法 frontmatter，并记录并发读取峰值；用于验证扫描并发与失败隔离。
private struct ManifestDownloadStatistics: Sendable {
    var previewCount = 0
    var maxActive = 0
}

private struct ManifestTestDownloader: RepoFileDownloading {
    let paths: [String]
    var invalidPath: String?
    var delay: Duration = .zero
    private let recorder = ManifestDownloadRecorder()

    var statistics: ManifestDownloadStatistics {
        recorder.statistics
    }

    private func manifest(path: String) -> String {
        let name = path.split(separator: "/").dropLast().last.map(String.init) ?? "skill"
        if path == invalidPath { return "# No frontmatter" }
        return "---\nname: \(name)\ndescription: Skill \(name)\n---\n# \(name)"
    }

    func download(owner: String, repo: String, sha: String, relativePath: String, toRoot root: URL,
                  onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let url = root.appendingPathComponent(repo).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(manifest(path: relativePath).utf8).write(to: url)
        onProgress?(1)
        return url
    }

    func preview(owner: String, repo: String, sha: String, relativePath: String, hintedSize: Int?) async throws -> RepoFilePreview {
        recorder.begin()
        defer { recorder.end() }
        try await Task.sleep(for: delay)
        return .text(manifest(path: relativePath))
    }
}

/// 计数器被 downloader 值语义拷贝，必须用引用类型记录同一个扫描内的并发峰值。
private final class ManifestDownloadRecorder: Sendable {
    private struct State {
        var active = 0
        var statistics = ManifestDownloadStatistics()
    }

    private let state = Mutex(State())

    var statistics: ManifestDownloadStatistics {
        state.withLock { $0.statistics }
    }

    func begin() -> Int {
        state.withLock {
            $0.active += 1
            $0.statistics.previewCount += 1
            $0.statistics.maxActive = max($0.statistics.maxActive, $0.active)
            return $0.active
        }
    }

    func end() {
        state.withLock { $0.active -= 1 }
    }
}

private func installSkill() -> RepoSkill {
    let files = ["SKILL.md", "scripts/check.sh", "references/guide.md"].map {
        RepoSkillFile(path: $0, sha: RepoFileDownloader.gitBlobSHA(Data($0.utf8)), size: $0.utf8.count,
                      mode: $0.hasSuffix(".sh") ? "100755" : "100644")
    }
    return RepoSkill(repositoryID: 1, commitSHA: "fixed", directory: "skills/review/", name: "review",
                     summary: "Review", manifest: "Review", files: files, installationIssue: nil)
}

/// 固定 blob 内容使测试同时覆盖下载后的 hash 检查，失败点位于附属文件而非首文件。
private struct SkillTestDownloader: RepoFileDownloading {
    var failing = false
    var delay: Duration = .zero

    func download(owner: String, repo: String, sha: String, relativePath: String, toRoot root: URL,
                  onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        try await Task.sleep(for: delay)
        if failing && relativePath != "SKILL.md" { throw RepoSkillError.verification }
        let url = root.appendingPathComponent(repo).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(relativePath.utf8).write(to: url)
        onProgress?(1)
        return url
    }

    func preview(owner: String, repo: String, sha: String, relativePath: String, hintedSize: Int?) async throws -> RepoFilePreview {
        .text("---\nname: review\ndescription: Review repositories\n---\n# Review")
    }
}
