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
    @Test("RepoContext 固定插入 metadata 后且缺 metadata 时置顶")
    func ordersRepoContextAfterMetadata() {
        #expect(KnowledgeRAGBrowserManagedItem.repoContextInsertionIndex(in: [.metadata, .readme]) == 1)
        #expect(KnowledgeRAGBrowserManagedItem.repoContextInsertionIndex(in: [.readme, .metadata, .notes]) == 2)
        #expect(KnowledgeRAGBrowserManagedItem.repoContextInsertionIndex(in: [.readme, .notes]) == 0)
    }

    @Test("XML 下载文件名稳定且写入当前草稿")
    func exportsCurrentDraft() throws {
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
