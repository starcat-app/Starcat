//
//  SkillRepositoryImportTests.swift
//  StarcatTests
//
//  仓库详情入口必须导入用户正在看的固定版本；测试不打开窗口，
//  也不使用默认分支最新响应代替原始预览证据。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Skill 仓库详情添加到库")
struct SkillRepositoryImportTests {
    @Test("固定 commit 不请求最新分支，后续更新仍跟踪来源分支")
    func importsDisplayedCommit() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let request = try await request()
        let counter = UpdateRequestCounter()
        let api = api()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            await counter.hit("latest")
            throw RepoSkillError.verification
        }
        let service = try service(fixture, api: api)
        let preview = try await service.prepareRepositorySkill(request)
        #expect(preview.plan.revision.upstreamCommit == SkillImportServiceTests.commit)
        #expect(preview.plan.entry.trackingRef == "release/next")
        #expect(preview.plan.source.defaultRef == "release/next")
        #expect(await counter.value("latest") == 0)
        #expect(await service.execute(preview).status == .succeeded)
        let snapshot = try await fixture.store.snapshot()
        #expect(snapshot.entries.first?.trackingRef == "release/next")
        #expect(snapshot.revisions.first?.upstreamCommit == request.skill.commitSHA)
        #expect(snapshot.assignments.isEmpty)
    }

    @Test("错误仓库、非固定提交与不可安装证据在网络及建库前拒绝", arguments: [0, 1, 2])
    func rejectsInvalidEvidence(kind: Int) async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let original = try await request()
        let skill = Self.skill(
            repositoryID: kind == 0 ? 2 : 1,
            commit: kind == 1 ? "HEAD" : SkillImportServiceTests.commit,
            issue: kind == 2 ? "unsupported files" : nil
        )
        let downloader = ImportTestDownloader()
        let service = try service(fixture, api: api(), downloader: downloader)
        await #expect(throws: SkillImportError.source) {
            try await service.prepareRepositorySkill(.init(repo: original.repo, skill: skill))
        }
        #expect(await downloader.downloadCount == 0)
        #expect(!SkillFilePrimitives.exists(fixture.store.paths.database))
    }

    @Test("来源名称与正在查看的名称不符，清理临时下载且不入库")
    func rejectsChangedManifestName() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let original = try await request()
        let skill = Self.skill(name: "different")
        let downloader = ImportTestDownloader()
        let service = try service(fixture, api: api(), downloader: downloader)
        await #expect(throws: SkillOperationError.planChanged) {
            try await service.prepareRepositorySkill(.init(repo: original.repo, skill: skill))
        }
        let downloads = try #require(await downloader.lastRoot)
        #expect(!SkillFilePrimitives.exists(downloads))
        #expect(try await fixture.store.snapshot().entries.isEmpty)
    }

    @Test("Direct 复用窗口与会话，已有审核不被后续请求替换")
    @MainActor
    func reusesPresentation() async throws {
        let request = try await request()
        var factories = 0
        var calls: [String] = []
        let coordinator = SkillWorkspaceSceneCoordinator(distributionGate: .init(channel: .direct)) {
            factories += 1
            return SkillWorkspaceViewModel()
        }
        try coordinator.openRepositoryImport(request) { calls.append($0) }
        let other = SkillRepositoryImportRequest(
            repo: request.repo, skill: Self.skill(commit: String(repeating: "b", count: 40))
        )
        try coordinator.openRepositoryImport(other) { calls.append($0) }
        #expect(factories == 1)
        #expect(calls.count == 2)
        #expect(coordinator.viewModel?.importPresentation?.repositoryRequest?.id == request.id)
        #expect(coordinator.viewModel?.libraryEnvironment == nil)
    }

    @Test("App Store 定位入口拒绝且不创建窗口会话")
    @MainActor
    func rejectsAppStoreNavigation() async throws {
        let request = try await request()
        var factories = 0
        var calls = 0
        let coordinator = SkillWorkspaceSceneCoordinator(distributionGate: .init(channel: .appStore)) {
            factories += 1
            return SkillWorkspaceViewModel()
        }
        #expect(throws: DistributionGateError.self) {
            try coordinator.openRepositoryImport(request) { _ in calls += 1 }
        }
        #expect(factories == 0)
        #expect(calls == 0)
    }

    private func request() async throws -> SkillRepositoryImportRequest {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1)
        var repo = try #require(try await GRDBRepoRepository(database: database).findById(1))
        repo.defaultBranch = "release/next"
        return .init(repo: repo, skill: Self.skill())
    }

    private static func skill(
        repositoryID: Int64 = 1, commit: String = SkillImportServiceTests.commit, issue: String? = nil,
        name: String = "sample"
    ) -> RepoSkill {
        RepoSkill(
            repositoryID: repositoryID, commitSHA: commit, directory: "", name: name,
            summary: "Sample", manifest: "# Sample",
            files: SkillImportServiceTests.files.map { .init(path: $0.path, sha: $0.sha, size: $0.size, mode: $0.mode) },
            installationIssue: issue
        )
    }

    private func api() -> MockGitHubAPIClient {
        let api = MockGitHubAPIClient()
        api.repositoryGitTreeHandler = { _, _, ref in
            #expect(ref == SkillImportServiceTests.commit)
            return .init(sha: ref, truncated: false, tree: SkillImportServiceTests.files)
        }
        return api
    }

    private func service(
        _ fixture: SkillOperationFixture, api: MockGitHubAPIClient, downloader: ImportTestDownloader = ImportTestDownloader()
    ) throws -> SkillImportService {
        try SkillImportService(
            store: fixture.store, operations: fixture.coordinator(), distributionGate: .init(channel: .direct),
            tokenProvider: ImportTestToken(), makeClients: { _ in .init(api: api, downloader: downloader) }
        )
    }
}
