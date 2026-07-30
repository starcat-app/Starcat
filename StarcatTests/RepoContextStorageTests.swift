//
//  RepoContextStorageTests.swift
//  StarcatTests
//
//  验证知识库浏览器管理 RepoContext XML 时的文件真源、校验、metadata 派生值与删除边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoContextStorage")
@MainActor
struct RepoContextStorageTests {
    @Test("主动生成状态映射覆盖缓存检查、下载与打包")
    func mapsRepoContextGenerationProgress() {
        #expect(RepoContextGenerationStep.map(.resolvingBranch) == .resolving)
        #expect(RepoContextGenerationStep.map(.checkingCache) == .resolving)
        #expect(RepoContextGenerationStep.map(.downloadingArchive) == .downloading)
        #expect(RepoContextGenerationStep.map(.packingContext) == .packing)
        #expect(RepoContextGenerationState.preparing(.packing).isActive)
        #expect(!RepoContextGenerationState.succeeded(cacheHit: true).isActive)
        #expect(!RepoContextGenerationState.failed(message: "failure", reason: nil).isActive)
        #expect(!RepoContextGenerationState.cancelled.isActive)
    }

    @Test("特殊 XML 生成结果必须同时匹配请求与仓库身份")
    func rejectsStaleSpecialContextGenerationIdentity() {
        let currentID = UUID()
        let identity = SpecialContextGenerationIdentity(id: currentID, repoID: 42)

        #expect(identity.accepts(currentID: currentID, selectedRepoID: 42))
        // 洞察 XML 与 RepoContext 共用这一所有权门禁：取消、切仓或新请求都会拒绝旧结果。
        #expect(!identity.accepts(currentID: UUID(), selectedRepoID: 42))
        #expect(!identity.accepts(currentID: currentID, selectedRepoID: 84))
        #expect(!identity.accepts(currentID: nil, selectedRepoID: 42))
        #expect(!identity.accepts(currentID: currentID, selectedRepoID: nil))
    }

    @Test("切仓会清除所有 RepoContext 生成展示状态")
    func resetsRepoContextGenerationPresentationOnRepositoryChange() {
        let states: [RepoContextGenerationState] = [
            .idle,
            .preparing(.downloading),
            .succeeded(cacheHit: false),
            .failed(message: "failure", reason: .archiveTooLarge),
            .cancelled,
        ]

        for state in states {
            #expect(state.resetForRepositoryLifecycle() == .idle)
        }
    }

    @Test("特殊 XML 固定插入 metadata 后且缺 metadata 时置顶")
    func ordersSpecialContextsAfterMetadata() throws {
        #expect(KnowledgeRAGBrowserManagedItem.specialContextInsertionIndex(in: [.metadata, .readme]) == 1)
        #expect(KnowledgeRAGBrowserManagedItem.specialContextInsertionIndex(in: [.readme, .metadata, .notes]) == 2)
        #expect(KnowledgeRAGBrowserManagedItem.specialContextInsertionIndex(in: [.readme, .notes]) == 0)

        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repoContext = try #require(
            try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo)
        )
        let insightsDocument = RepositoryInsightsDocument(
            repositoryID: 42,
            repositoryFullName: "microsoft/vscode",
            generatedAt: Date(timeIntervalSince1970: 1_753_660_800),
            sourceHash: "source-hash",
            xml: "<repository_insights repository_id=\"42\" />"
        )
        let insights = RepositoryInsightsContextArtifact(
            document: insightsDocument,
            metadata: RepositoryInsightsContextMetadata(
                schemaVersion: RepositoryInsightsContextMetadata.schemaVersion,
                repositoryID: insightsDocument.repositoryID,
                repositoryFullName: insightsDocument.repositoryFullName,
                accountStorageKey: "user-1",
                generatedAt: insightsDocument.generatedAt,
                sourceHash: insightsDocument.sourceHash,
                xmlHash: "xml-hash"
            )
        )

        let items = KnowledgeRAGBrowserManagedItem.merge(
            chunks: [],
            repositoryInsights: insights,
            repoContext: repoContext
        )

        #expect(items.count == 2)
        if case .repositoryInsights = items[0] {} else {
            Issue.record("缺 Metadata 时洞察 XML 应位于第一个特殊项")
        }
        if case .repoContext = items[1] {} else {
            Issue.record("RepoContext XML 应位于洞察 XML 之后")
        }
    }

    @Test("XML 下载文件名稳定且写入当前草稿")
    func exportsCurrentDraft() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let cachedBeforeExport = try #require(
            try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo)
        )
        #expect(
            RepoContextXMLExport.defaultFilename(owner: "microsoft", repo: "vscode")
                == "microsoft-vscode-context.xml"
        )
        #expect(
            RepoContextXMLExport.defaultFilename(owner: "owner/name", repo: "repo:test")
                == "owner-name-repo-test-context.xml"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-repocontext-export-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        let draft = "<repository><draft>尚未保存</draft></repository>"

        try RepoContextXMLExport.writeDraft(draft, to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == draft)
        let cachedAfterExport = try #require(
            try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo)
        )
        #expect(cachedAfterExport.xml == cachedBeforeExport.xml)
        #expect(cachedAfterExport.metadata.stats == cachedBeforeExport.metadata.stats)
        #expect(cachedAfterExport.metadata.generationCount == cachedBeforeExport.metadata.generationCount)
    }

    @Test("RepoContext 独立统计只取决于 XML 是否存在")
    func reportsIndependentRepoContextAvailability() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let document = try #require(
            try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo)
        )

        #expect(KnowledgeRAGBrowserManagedItem.singletonAvailability(false) == "0 / 1")
        #expect(KnowledgeRAGBrowserManagedItem.singletonAvailability(document.xml.isEmpty == false) == "1 / 1")
    }

    @Test("洞察 XML 下载使用安全文件名并原子写入原文")
    func exportsRepositoryInsightsXML() throws {
        #expect(
            RepositoryInsightsXMLExport.defaultFilename(repositoryFullName: "microsoft/vscode")
                == "microsoft-vscode-insights.xml"
        )
        #expect(
            RepositoryInsightsXMLExport.defaultFilename(repositoryFullName: "owner/name:repo")
                == "owner-name-repo-insights.xml"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-insights-export-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = "<repository_insights repository_id=\"42\" />"

        try RepositoryInsightsXMLExport.write(xml, to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == xml)
    }

    @Test("合法编辑原子更新 XML 与 metadata，但不增加生成次数")
    func savesEditedDocumentAndDerivedMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let loadedOriginal = try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo)
        let original = try #require(loadedOriginal)
        let editedXML = "<?xml version=\"1.0\"?><repository><file path=\"Sources/App.swift\">print(1)</file></repository>"

        let edited = try fixture.storage.saveEditedContextXML(
            editedXML,
            owner: fixture.owner,
            repo: fixture.repo
        )

        #expect(edited.xml == editedXML)
        #expect(edited.metadata.stats.actualTokens == TokenEstimator.estimate(text: editedXML))
        #expect(edited.metadata.stats.contextXmlBytes == editedXML.utf8.count)
        #expect(edited.metadata.generationCount == original.metadata.generationCount)
        #expect(edited.metadata.generatedAt == original.metadata.generatedAt)
        #expect(edited.metadata.lastAccessedAt != nil)
    }

    @Test("非法 XML 与错误根节点不会覆盖现有文档")
    func rejectsInvalidDocumentsWithoutOverwriting() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let loadedOriginal = try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo)
        let original = try #require(loadedOriginal)

        #expect(throws: RepoContextStorageError.self) {
            try fixture.storage.saveEditedContextXML(
                "<repository>",
                owner: fixture.owner,
                repo: fixture.repo
            )
        }
        #expect(throws: RepoContextStorageError.self) {
            try fixture.storage.saveEditedContextXML(
                "<context />",
                owner: fixture.owner,
                repo: fixture.repo
            )
        }

        let loadedAfterFailures = try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo)
        let reloaded = try #require(loadedAfterFailures)
        #expect(reloaded.xml == original.xml)
        #expect(reloaded.metadata.stats == original.metadata.stats)
    }

    @Test("删除会移除完整项目产物并同步汇总")
    func deletesProjectArtifacts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        #expect(fixture.storage.projectCount == 1)

        try fixture.storage.deleteProject(owner: fixture.owner, repo: fixture.repo)

        #expect(try fixture.storage.loadDocument(owner: fixture.owner, repo: fixture.repo) == nil)
        #expect(fixture.storage.projectCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectURL.path))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-repocontext-storage-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "RepoContextStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let storage = RepoContextStorage(
            fileManager: .default,
            defaults: defaults,
            fixedRootURL: root
        )
        let owner = "microsoft"
        let repo = "vscode"
        let xml = "<?xml version=\"1.0\"?><repository><file path=\"README.md\">Hello</file></repository>"
        let stats = PackStats(
            totalFiles: 1,
            tier0Count: 1,
            tier1Count: 0,
            tier2Count: 0,
            estimatedTokens: TokenEstimator.estimate(text: xml),
            actualTokens: TokenEstimator.estimate(text: xml),
            contextXmlBytes: xml.utf8.count
        )
        let metadata = PackMetadata(
            schemaVersion: 1,
            tierRulesVersion: TierRules.tierRulesVersion,
            tokenEstimatorVersion: TierRules.tokenEstimatorVersion,
            owner: owner,
            repo: repo,
            ref: "main",
            commitSha: "abc123",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tokenBudget: 8_000,
            stats: stats,
            skippedFiles: [],
            warnings: [],
            tier1MaxLines: 80
        )
        _ = try storage.write(xml: xml, metadata: metadata, owner: owner, repo: repo)
        storage.reload()
        return Fixture(
            storage: storage,
            root: root,
            suiteName: suiteName,
            owner: owner,
            repo: repo
        )
    }

    private struct Fixture {
        let storage: RepoContextStorage
        let root: URL
        let suiteName: String
        let owner: String
        let repo: String

        var projectURL: URL {
            root.appendingPathComponent(owner, isDirectory: true)
                .appendingPathComponent(repo, isDirectory: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }
}
