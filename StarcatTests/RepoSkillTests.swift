//
//  RepoSkillTests.swift
//  StarcatTests
//
//  Skill 真实链路回归：识别证据、分页前 SQL 筛选、完整目录发布与失败保护。
//  安装全部使用独立临时目录，不写用户的 Agent 目录。
//

import Foundation
import GRDB
import Observation
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

    /// 使用独立提交与临时目录跑完整会话，避免进程级 Git tree 缓存或真实工具目录影响测试。
    @MainActor
    private func agentSession(destinations: [RepoSkillDestination]) async throws -> RepoSkillSession {
        let database = try InMemoryDatabaseManager()
        let api = MockGitHubAPIClient()
        let commit = UUID().uuidString
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: commit, commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: [
                skillEntry("SKILL.md", sha: RepoFileDownloader.gitBlobSHA(Data("SKILL.md".utf8)))
            ])
        }
        let store = RepoSkillStore(database: database, publicAPI: api, privateAPI: api,
                                   publicDownloader: SkillTestDownloader(), privateDownloader: SkillTestDownloader())
        let defaults = try #require(UserDefaults(suiteName: "skills-agents-\(UUID().uuidString)"))
        let session = RepoSkillSession(repo: try await repo(), store: store, destinations: destinations, defaults: defaults)
        await session.load()
        try #require(session.skills.count == 1)
        return session
    }

    @MainActor
    private func waitForAgentOperation(_ session: RepoSkillSession) async throws {
        for _ in 0..<400 {
            if !session.isInstalling && !session.isCheckingDestination { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!session.isInstalling && !session.isCheckingDestination)
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
        // 预览保留原始 frontmatter，由阅读渲染器转成键值表格。
        #expect(result.skills[0].manifest.hasPrefix("---\n"))
        #expect(result.skills[0].manifest.hasSuffix("# Review"))
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
        #expect(observedCounts.first == 1)
        #expect(scan.complete && scan.skills.count == 3)
        #expect(scan.manifestTotal == 3 && scan.manifestChecked == 3)
    }

    @Test("manifest 小并发读取；无效候选保留预览与告警，不影响同批有效 Skill")
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
        #expect(scan.presence == .contains && scan.skills.count == 6)
        #expect(!scan.complete && scan.manifestChecked == 6 && scan.manifestTotal == 6)
        #expect(scan.diagnostics.count == 1 && scan.diagnostics[0].contains(broken))
        let invalidSkill = try #require(scan.skills.first { $0.manifestPath == broken })
        #expect(invalidSkill.name == "skill-3")
        #expect(invalidSkill.manifest == "# No frontmatter")
        #expect(invalidSkill.files.map(\.path) == ["SKILL.md"])
        #expect(invalidSkill.installationIssue == RepoSkillError.invalidManifest.localizedDescription)
        #expect(scan.skills.filter { $0.manifestPath != broken }.allSatisfy { $0.installationIssue == nil })
        let stats = downloader.statistics
        #expect(stats.previewCount == 6 && stats.maxActive >= 2 && stats.maxActive <= 4)
    }

    @Test("根目录与嵌套目录的无效描述仍计入 Skill，原文和附件完整保留",
          arguments: ["SKILL.md", "skills/in-progress/software-factory/SKILL.md"])
    func invalidDescriptionsRemainVisible(path: String) async throws {
        let api = MockGitHubAPIClient()
        let directory = String(path.dropLast("SKILL.md".count))
        let attachmentPath = directory + "guide.md"
        let markdown = "---\nname: software-factory\ndescription: [unsupported, syntax]\n---\n# Original"
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "fixed", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: [
                skillEntry(path, sha: "manifest"), skillEntry(attachmentPath, sha: "guide")
            ])
        }
        let source = try await repo()
        let scan = try await RepoSkillScanner(
            api: api,
            downloader: ManifestTestDownloader(paths: [path], invalidPath: path, invalidManifest: markdown),
            cache: RepoFileTreeSessionCache(), cacheScope: UUID().uuidString
        ).scan(source)
        let skill = try #require(scan.skills.first)
        #expect(scan.skills.count == 1 && scan.presence == .contains && !scan.complete)
        #expect(skill.name == (directory.isEmpty ? source.name : "software-factory"))
        #expect(skill.manifest == markdown && skill.summary.isEmpty)
        #expect(Set(skill.files.map(\.path)) == ["SKILL.md", "guide.md"])
        #expect(skill.installationIssue == RepoSkillError.invalidManifest.localizedDescription)
        #expect(scan.diagnostics.count == 1 && scan.diagnostics[0].contains(path))
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

    @Test("卸载完整 Skill 并保留其它目录；重复卸载可安全完成")
    func uninstallOwnedSkill() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = RepoSkillDestination(preset: .codex, url: root)
        let installer = RepoSkillInstaller(downloader: SkillTestDownloader())
        let skill = installSkill()
        try await installer.install(skill, repo: try await repo(), destination: destination, replacing: false, onProgress: { _ in })
        let sibling = root.appendingPathComponent("other.txt")
        try Data("preserve".utf8).write(to: sibling)
        try await installer.uninstall(skill, destination: destination)
        #expect(try await installer.existing(skill, destination: destination) == .missing)
        #expect(try String(contentsOf: sibling, encoding: .utf8) == "preserve")
        try await installer.uninstall(skill, destination: destination)
    }

    @Test("卸载拒绝外部安装、本地修改、额外文件与软链接", arguments: ["external", "modified", "extra", "symlink"])
    func uninstallPreservesUnownedChanges(_ change: String) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = RepoSkillInstaller(downloader: SkillTestDownloader())
        let destination = RepoSkillDestination(preset: .agents, url: root)
        let skill = installSkill()
        try await installer.install(skill, repo: try await repo(), destination: destination, replacing: false, onProgress: { _ in })
        let folder = root.appendingPathComponent(skill.name)
        switch change {
        case "external":
            try FileManager.default.removeItem(at: folder.appendingPathComponent(".starcat-install.json"))
        case "modified":
            try Data("local edit".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        case "extra":
            try Data("user data".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        default:
            let actual = root.appendingPathComponent("actual")
            try FileManager.default.moveItem(at: folder, to: actual)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: actual)
        }
        let before = try Data(contentsOf: folder.appendingPathComponent("SKILL.md"))
        await #expect(throws: (any Error).self) { try await installer.uninstall(skill, destination: destination) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("SKILL.md")) == before)
        if change == "extra" { #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path)) }
    }

    @Test("卸载开始前取消保留完整安装")
    func cancelledUninstallPreservesInstallation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = RepoSkillInstaller(downloader: SkillTestDownloader())
        let destination = RepoSkillDestination(preset: .agents, url: root)
        let skill = installSkill()
        try await installer.install(skill, repo: try await repo(), destination: destination, replacing: false, onProgress: { _ in })
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await installer.uninstall(skill, destination: destination)
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try await installer.existing(skill, destination: destination) == .installed)
    }

    @Test("工具检测只读应用、可执行文件、配置和扩展；导出过 skills 不等于安装工具")
    func detectLocalAgentsWithoutLaunchingTools() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        let binaries = root.appendingPathComponent("bin")
        for path in [".claude", ".cursor/skills", ".vscode/extensions/rooveterinaryinc.roo-cline-1.0",
                     "Applications/Windsurf.app", "bin"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        let binary = binaries.appendingPathComponent("gemini")
        try Data("This file must never be executed.".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let targets = await RepoSkillAgentCatalog.detect(home: root, environment: [:],
                                                        applicationDirectories: [applications], executableDirectories: [binaries])
        #expect(Set(targets.map(\.preset)) == [.agents, .claudeCode, .geminiCLI, .windsurf, .rooCode])
        #expect(targets.first { $0.preset == .windsurf }?.applicationPath == applications.appendingPathComponent("Windsurf.app").path)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".gemini/skills").path))
    }

    @Test("工具目录尊重配置环境变量；共用目录使用相同身份")
    func agentDirectoryOverridesAndSharedIdentity() {
        let home = URL(fileURLWithPath: "/tmp/starcat-agent-home")
        let environment = ["CLAUDE_CONFIG_DIR": "/tmp/starcat-custom-claude", "XDG_CONFIG_HOME": "/tmp/starcat-custom-xdg",
                           "CODEX_HOME": "/tmp/starcat-custom-codex"]
        #expect(RepoSkillTargetPreset.claudeCode.agent.directoryURL(home: home, environment: environment).path
                == "/tmp/starcat-custom-claude/skills")
        #expect(RepoSkillTargetPreset.openCode.agent.directoryURL(home: home, environment: environment).path
                == "/tmp/starcat-custom-xdg/opencode/skills")
        #expect(RepoSkillTargetPreset.codex.agent.configurationURL(home: home, environment: environment).path
                == "/tmp/starcat-custom-codex")
        let agents = RepoSkillTargetPreset.agents.agent.directoryURL(home: home, environment: environment)
        for preset in [RepoSkillTargetPreset.codex, .cline, .kimiCode, .pi, .warp, .zed] {
            #expect(preset.agent.directoryURL(home: home, environment: environment) == agents)
        }
    }

    @MainActor
    @Test("胶囊立即安装/卸载，共用目录去重；全选/清空只配置批量目标")
    func directAndBatchAgentOperations() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = RepoSkillDestination(preset: .agents, url: root.appendingPathComponent("shared"))
        let codex = RepoSkillDestination(preset: .codex, url: shared.url)
        let claude = RepoSkillDestination(preset: .claudeCode, url: root.appendingPathComponent("claude"))
        let session = try await agentSession(destinations: [shared, codex, claude])
        defer { session.close() }
        session.selectAllDestinations(true)
        try await waitForAgentOperation(session)
        #expect(session.agentTargets.count == 3 && session.plannedItems.count == 2)
        #expect(!FileManager.default.fileExists(atPath: shared.url.path))
        session.toggleAgent(codex.id)
        try await waitForAgentOperation(session)
        #expect(session.queue.count == 1 && !session.hasFailures)
        #expect(session.isInstalled(at: shared.id) && session.isInstalled(at: codex.id))
        #expect(!session.isInstalled(at: claude.id))
        #expect(session.canStart && session.plannedItems.count == 1)
        session.start()
        try await waitForAgentOperation(session)
        #expect(session.isInstalled(at: claude.id))
        session.selectAllDestinations(false)
        try await waitForAgentOperation(session)
        #expect(session.selectedDestinationIDs.isEmpty)
        #expect(session.isInstalled(at: shared.id) && session.isInstalled(at: claude.id))
        session.toggleAgent(shared.id)
        try await waitForAgentOperation(session)
        #expect(!session.isInstalled(at: codex.id) && session.isInstalled(at: claude.id))
        #expect(session.queue.allSatisfy { $0.operation == .uninstall && $0.status == .succeeded })
        session.toggleAgent(codex.id)
        try await waitForAgentOperation(session)
        #expect(session.isInstalled(at: shared.id))
        #expect(session.queue.allSatisfy { $0.operation == .install && $0.status == .succeeded })
    }

    @MainActor
    @Test("未勾选 Skill 时胶囊安装当前阅读项；失败队列不污染下一个直接操作")
    func directAgentOperationAfterFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let first = RepoSkillDestination(preset: .agents, url: blocked)
        let second = RepoSkillDestination(preset: .claudeCode, url: root.appendingPathComponent("claude"))
        let session = try await agentSession(destinations: [first, second])
        defer { session.close() }
        session.selectAll(false)
        session.focusSkill(session.skills.first?.id)
        #expect(session.selectedIDs.isEmpty)
        session.toggleAgent(first.id)
        try await waitForAgentOperation(session)
        #expect(session.hasFailures)
        session.toggleAgent(second.id)
        try await waitForAgentOperation(session)
        #expect(session.isInstalled(at: second.id) && !session.hasFailures)
        #expect(session.queue.count == 1 && session.queue.first?.destination.id == second.id)
        session.toggleAgent(second.id)
        try await waitForAgentOperation(session)
        #expect(!session.isInstalled(at: second.id) && !session.hasFailures)
        #expect(session.queue.first?.operation == .uninstall)
    }

    @MainActor
    @Test("直接安装遇到同名目录先等待替换决定，确认后继续原操作")
    func directAgentInstallationResumesAfterConflict() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = RepoSkillDestination(preset: .agents, url: root)
        let folder = root.appendingPathComponent("review")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("SKILL.md")
        try Data("external content".utf8).write(to: manifest)
        let session = try await agentSession(destinations: [destination])
        defer { session.close() }
        session.toggleAgent(destination.id)
        #expect(session.phase == .ready && session.conflicts.count == 1)
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "external content")
        let conflict = try #require(session.conflicts.first)
        session.resolveConflict(conflict.id, replacing: true)
        try await waitForAgentOperation(session)
        #expect(session.isInstalled(at: destination.id))
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "SKILL.md")
    }

    @MainActor
    @Test("卸载失败或取消后重试继续卸载，不启动其它目录的安装", arguments: [false, true])
    func retryUninstallKeepsItsOperation(_ cancel: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RepoSkillDestination(preset: .agents, url: root.appendingPathComponent("shared"))
        let second = RepoSkillDestination(preset: .claudeCode, url: root.appendingPathComponent("claude"))
        let session = try await agentSession(destinations: [first, second])
        defer { session.close() }
        session.selectAllDestinations(true)
        try await waitForAgentOperation(session)
        session.toggleAgent(first.id)
        try await waitForAgentOperation(session)
        let manifest = first.url.appendingPathComponent("review/SKILL.md")
        if !cancel { try Data("local edit".utf8).write(to: manifest) }
        session.toggleAgent(first.id)
        if cancel { session.cancel() }
        try await waitForAgentOperation(session)
        #expect(session.isUninstalling && session.canStart)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        if !cancel {
            #expect(session.hasFailures)
            #expect(try String(contentsOf: manifest, encoding: .utf8) == "local edit")
            try Data("SKILL.md".utf8).write(to: manifest)
        }
        session.start()
        try await waitForAgentOperation(session)
        #expect(!session.hasFailures && session.phase == .finished)
        #expect(session.queue.allSatisfy { $0.operation == .uninstall && $0.status == .succeeded })
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
    }

    @MainActor
    @Test("扫描计数仅在手动重新检测期间显示，完成与失败后收起")
    func manualScanProgress() async throws {
        let db = try InMemoryDatabaseManager()
        let api = MockGitHubAPIClient()
        let paths = ["skills/review/SKILL.md"]
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: paths.map { skillEntry($0, sha: "manifest") })
        }
        let store = RepoSkillStore(
            database: db, publicAPI: api, privateAPI: api,
            publicDownloader: ManifestTestDownloader(paths: paths),
            privateDownloader: ManifestTestDownloader(paths: paths)
        )
        let defaults = try #require(UserDefaults(suiteName: "skills-progress-\(UUID().uuidString)"))
        let session = RepoSkillSession(repo: try await repo(), store: store, destinations: [], defaults: defaults)
        defer { session.close() }
        api.repositoryLatestCommitHandler = { [weak session] _, _, _, _ in
            let session = try #require(session)
            #expect(session.isLoading)
            #expect(session.scanProgressText == nil)
            return GitHubCommitSummaryDTO(
                sha: "progress-initial", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil)
            )
        }
        await session.load()
        #expect(session.skills.count == 1)
        #expect(session.scanProgressText == nil)

        // 在 API 悬挂点检查会话，覆盖真实加载周期，而非手动设置 UI 状态。
        api.repositoryLatestCommitHandler = { [weak session] _, _, _, _ in
            let session = try #require(session)
            #expect(session.isLoading)
            #expect(session.scanProgressText != nil)
            return GitHubCommitSummaryDTO(
                sha: "progress-manual", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil)
            )
        }
        await session.load(force: true)
        #expect(!session.isLoading)
        #expect(session.error == nil)
        #expect(session.scanProgressText == nil)

        api.repositoryLatestCommitHandler = { [weak session] _, _, _, _ in
            #expect(session?.scanProgressText != nil)
            throw URLError(.timedOut)
        }
        await session.load(force: true)
        #expect(session.error != nil)
        #expect(!session.isLoading)
        #expect(session.scanProgressText == nil)
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

    @Test("v27 一次性回填数量与完整性，保留旧正文并容忍损坏的可重建缓存")
    func summaryMigrationPreservesPayload() async throws {
        let queue = try DatabaseQueue()
        var migrations = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrations)
        try migrations.migrate(queue, upTo: "v26-recommendation-history")
        let payload = try JSONEncoder().encode(RepoSkillScan(
            repositoryID: 1, commitSHA: "fixed", sourcePushedAt: nil, sourceBranch: nil,
            checkedAt: .now, complete: true, skills: [installSkill()], diagnostics: [],
            manifestTotal: 1, manifestChecked: 1, version: RepoSkillScan.rulesVersion
        ))
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo_skill_scans
                (repo_id, commit_sha, rules_version, expires_at, presence, payload)
                VALUES (1, 'fixed', 3, 4000000000, 'contains', ?),
                       (2, 'invalid', 3, 4000000000, 'unknown', X'00')
                """, arguments: [payload])
        }
        try migrations.migrate(queue)
        try await queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM repo_skill_scans WHERE repo_id = 1"))
            #expect(row["skill_count"] as Int == 1)
            #expect(row["is_complete"] as Bool)
            #expect(row["payload"] as Data == payload)
            #expect(try Int.fetchOne(db, sql: "SELECT skill_count FROM repo_skill_scans WHERE repo_id = 2") == 0)
        }
    }

    @MainActor
    @Test("徽标恢复只读摘要；正文按仓库读取，缓存命中不发网络请求")
    func summaryRestoreAvoidsPayloadReads() async throws {
        let db = try InMemoryDatabaseManager()
        let source = try await repo()
        let scan = RepoSkillScan(
            repositoryID: source.id, commitSHA: "cached",
            sourcePushedAt: source.pushedAt, sourceBranch: source.defaultBranch, checkedAt: .now,
            complete: true, skills: [installSkill()], diagnostics: [], manifestTotal: 1, manifestChecked: 1,
            version: RepoSkillScan.rulesVersion
        )
        let payload = try JSONEncoder().encode(scan)
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO repo_skill_scans
                (repo_id, commit_sha, pushed_at, branch, rules_version, expires_at, presence, payload,
                 skill_count, is_complete)
                VALUES (?, ?, ?, ?, ?, ?, 'contains', ?, 1, 1),
                       (999, 'other', NULL, NULL, ?, 4000000000, 'contains', X'00', 20, 0)
                """, arguments: [
                    source.id, scan.commitSHA, source.pushedAt, source.defaultBranch, scan.version,
                    scan.summary.expiresAt.timeIntervalSince1970, payload, RepoSkillScan.rulesVersion
                ])
        }
        let statements = Mutex<[String]>([])
        try await db.writer.write { db in
            db.trace { event in statements.withLock { $0.append(event.description) } }
        }
        let calls = Mutex(0)
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                  publicDownloader: SkillTestDownloader(), privateDownloader: SkillTestDownloader())
        await store.prepare()
        #expect(store.summaries.count == 2)
        #expect(try await store.detectSummary(source).skillCount == 1)
        #expect(store.presence(repositoryID: 999) == .contains)
        #expect(!statements.withLock { $0.contains { $0.contains("SELECT payload") } })
        let loaded = try #require(try await store.cachedScan(for: source))
        #expect(loaded.skills == scan.skills)
        #expect(try await store.detect(source).skills == scan.skills)
        #expect(calls.withLock { $0 } == 0)
        #expect(statements.withLock { values in
            let payloadReads = values.filter { $0.contains("SELECT payload") }
            return payloadReads.count == 2 && payloadReads.allSatisfy { $0.contains("WHERE repo_id =") }
        })
        var changed = source
        changed.defaultBranch = "new-default"
        #expect(store.presence(for: changed) == .unknown)
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
        #expect(restored.summaries.isEmpty && restored.isChangingAccount)
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

    @Test("两千个目录按前缀取完整附件；默认仍只探测 200 份 manifest")
    func largeTreeKeepsBudgetAndDirectoryBoundaries() async throws {
        let paths = (0..<2_000).map { "skills/skill-\($0)/SKILL.md" }
        let entries = paths.flatMap { path in
            let directory = String(path.dropLast("SKILL.md".count))
            return [
                skillEntry(path, sha: path),
                skillEntry(directory + "scripts/check.sh", sha: "script", mode: "100755"),
                skillEntry(directory + "references/guide.md", sha: "guide")
            ]
        }
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "large-tree-budget", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in GitHubGitTreeDTO(sha: "tree", truncated: false, tree: entries) }
        let updates = Mutex<[Int]>([])
        let result = try await RepoSkillScanner(
            api: api, downloader: ManifestTestDownloader(paths: paths),
            cache: RepoFileTreeSessionCache(), cacheScope: "large-tree"
        ).scan(try await repo()) { partial in updates.withLock { $0.append(partial.skills.count) } }
        #expect(result.manifestTotal == 2_000 && result.manifestChecked == 200)
        #expect(result.skills.count == 200 && !result.complete)
        #expect(updates.withLock { $0.first } == 4)
        #expect(result.skills.map(\.directory) == result.skills.map(\.directory).sorted())
        for skill in result.skills {
            #expect(skill.files.map(\.path) == ["SKILL.md", "references/guide.md", "scripts/check.sh"])
            #expect(skill.installationIssue == nil)
        }
    }

    @MainActor
    @Test("进行中的 partial 不冒充缓存；一个消费者取消不影响仍在浏览的窗口")
    func sharedScanConsumerCancellation() async throws {
        let db = try InMemoryDatabaseManager()
        let source = try await repo()
        let api = MockGitHubAPIClient()
        let paths = (0..<20).map { "skills/skill-\($0)/SKILL.md" }
        let downloader = ManifestTestDownloader(paths: paths, delay: .milliseconds(50))
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "shared-consumers", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: paths.map { skillEntry($0, sha: $0) })
        }
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                  publicDownloader: downloader, privateDownloader: downloader)
        let firstPartial = Mutex(false)
        let first = Task { try await store.detect(source) { _ in firstPartial.withLock { $0 = true } } }
        for _ in 0..<1_000 {
            if firstPartial.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(firstPartial.withLock { $0 })
        let listInvalidated = Mutex(false)
        withObservationTracking {
            _ = store.summaries
        } onChange: {
            listInvalidated.withLock { $0 = true }
        }
        let joined = Mutex(false)
        let second = Task {
            try await store.detect(source) { _ in
                #expect(!listInvalidated.withLock { $0 })
                joined.withLock { $0 = true }
            }
        }
        for _ in 0..<1_000 {
            if joined.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(joined.withLock { $0 })
        first.cancel()
        let final = try await second.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(final.complete && final.skills.count == 20)
        #expect(downloader.statistics.previewCount == 20)
        #expect(!store.scanningIDs.contains(source.id))
        #expect(listInvalidated.withLock { $0 })
        // prepare、unknown -> contains、最终 SQL 落库各一次，manifest 进度不递增全局修订。
        #expect(store.revision == 3)
    }

    @MainActor
    @Test("最后一个窗口取消后停止剩余 manifest 请求，清除未完成证据")
    func lastConsumerCancelsScan() async throws {
        let db = try InMemoryDatabaseManager()
        let source = try await repo()
        let api = MockGitHubAPIClient()
        let paths = (0..<100).map { "skills/skill-\($0)/SKILL.md" }
        let downloader = ManifestTestDownloader(paths: paths, delay: .milliseconds(50))
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: "last-consumer", commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(sha: "tree", truncated: false, tree: paths.map { skillEntry($0, sha: $0) })
        }
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                  publicDownloader: downloader, privateDownloader: downloader)
        let received = Mutex(false)
        let scanning = Task { try await store.detect(source) { _ in received.withLock { $0 = true } } }
        for _ in 0..<1_000 {
            if received.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(received.withLock { $0 })
        scanning.cancel()
        await #expect(throws: CancellationError.self) { try await scanning.value }
        #expect(!store.scanningIDs.contains(source.id))
        #expect(store.summaries[source.id] == nil)
        #expect(store.errors[source.id] == nil)
        #expect(downloader.statistics.previewCount < 100)
    }

    @MainActor
    @Test("五千条缓存 Skill 的覆盖和安装计划只随输入变化重建")
    func largeSessionSnapshot() async throws {
        let db = try InMemoryDatabaseManager()
        let source = try await repo()
        let skills = (0..<5_000).map { index in
            RepoSkill(repositoryID: source.id, commitSHA: "large-session", directory: "skills/skill-\(index)/",
                      name: "skill-\(index)", summary: "Summary", manifest: "# Skill \(index)",
                      files: installSkill().files, installationIssue: nil)
        }
        let scan = RepoSkillScan(
            repositoryID: source.id, commitSHA: "large-session",
            sourcePushedAt: source.pushedAt, sourceBranch: source.defaultBranch, checkedAt: .now,
            complete: true, skills: skills, diagnostics: [], manifestTotal: 5_000, manifestChecked: 5_000,
            version: RepoSkillScan.rulesVersion
        )
        let payload = try JSONEncoder().encode(scan)
        try await db.writer.write {
            try $0.execute(
                sql: """
                    INSERT INTO repo_skill_scans
                    (repo_id, commit_sha, pushed_at, branch, rules_version, expires_at, presence, payload,
                     skill_count, is_complete)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [source.id, scan.commitSHA, source.pushedAt, source.defaultBranch, scan.version,
                            scan.checkedAt.addingTimeInterval(86_400).timeIntervalSince1970, "contains", payload,
                            scan.skills.count, scan.complete]
            )
        }
        let api = MockGitHubAPIClient()
        let store = RepoSkillStore(database: db, publicAPI: api, privateAPI: api,
                                  publicDownloader: SkillTestDownloader(), privateDownloader: SkillTestDownloader())
        let defaults = try #require(UserDefaults(suiteName: "skills-large-\(UUID().uuidString)"))
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RepoSkillSession(
            repo: source, store: store, destinations: [RepoSkillDestination(preset: .agents, url: root)], defaults: defaults
        )
        await session.load()
        session.selectAll(true)
        #expect(session.skills.count == 5_000 && session.pendingSkills.count == 5_000)
        #expect(session.plannedItems.count == 5_000 && session.plannedGroups.count == 5_000)
        let revision = session.listRevision
        let clock = ContinuousClock()
        let start = clock.now
        let installedCount = session.skills.reduce(0) { count, skill in
            count + session.coverage(of: skill.id) + (session.installedIDs.contains(skill.id) ? 1 : 0)
        }
        let duration = start.duration(to: clock.now)
        print("Skill state benchmark: 5000 coverage + installed queries in \(duration)")
        #expect(installedCount == 0)
        // 宽松的算法回归门槛只拦截全量嵌套遍历，不把单元测试时间当作界面帧率。
        #expect(duration < .milliseconds(250))
        #expect(session.listRevision == revision)
        session.selectAll(false)
        #expect(session.pendingSkills.isEmpty && session.plannedGroups.isEmpty)
        session.close()
    }

    @Test("后台正文准备保留围栏和固定提交图片，文件树只分组一次")
    func readingPreparation() async throws {
        let cache = RepoSkillReadingCache()
        let original = installSkill()
        let skill = RepoSkill(
            repositoryID: original.repositoryID, commitSHA: original.commitSHA, directory: original.directory,
            name: original.name, summary: original.summary,
            manifest: """
            ---
            name: review
            description: Review repositories
            ---
            # Review

            ```swift
            let value = 1
            ```

            ![image](assets/example.png)

            [guide](references/guide.md)
            """,
            files: original.files, installationIssue: nil
        )
        let prepared = try await cache.prepare(
            skill, imageBaseURL: URL(string: "https://raw.githubusercontent.com/owner/repo/fixed/skills/review/")
        )
        #expect(prepared.html.contains("class=\"starcat-front-matter\""))
        #expect(prepared.html.contains(">Review repositories</td>"))
        #expect(prepared.html.contains("<h1>Review</h1>"))
        #expect(prepared.html.contains("<pre><code class=\"language-swift\">"))
        #expect(prepared.html.contains("https://raw.githubusercontent.com/owner/repo/fixed/skills/review/assets/example.png"))
        #expect(prepared.html.contains("href=\"references/guide.md\""))
        #expect(prepared.rootFiles.map(\.path) == ["SKILL.md"])
        #expect(prepared.folders.map(\.id) == ["references", "scripts"])
        let cancelled = Task {
            // 自取消后再进入 actor，确定性覆盖命中缓存时的取消，不依赖父子任务调度先后。
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.prepare(skill, imageBaseURL: nil)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
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
    var invalidManifest = "# No frontmatter"
    var delay: Duration = .zero
    private let recorder = ManifestDownloadRecorder()

    var statistics: ManifestDownloadStatistics {
        recorder.statistics
    }

    private func manifest(path: String) -> String {
        let name = path.split(separator: "/").dropLast().last.map(String.init) ?? "skill"
        if path == invalidPath { return invalidManifest }
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
