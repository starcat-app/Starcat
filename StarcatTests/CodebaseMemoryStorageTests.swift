//
//  CodebaseMemoryStorageTests.swift
//  StarcatTests
//
//  验证 CodebaseMemory 的项目隔离与共享 Graph UI 路由约束。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CodebaseMemoryStorage")
@MainActor
struct CodebaseMemoryStorageTests {

    @Test("App Store 内置版本仍使用 repo 独立 cache")
    func bundledCacheDirectoryRemainsRepoScoped() {
        let root = URL(fileURLWithPath: "/tmp/starcat-codebase-memory", isDirectory: true)
        let storage = CodebaseMemoryStorage(
            fileManager: .default,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        let cache = storage.projectCacheDirectory(root: root, owner: "owner", name: "repo")

        #expect(cache == root.appendingPathComponent("owner/repo/.internal-cache", isDirectory: true))
    }

    @Test("Starcat 项目名包含 GitHub ID，避免 canonical cache 同名碰撞")
    func stableProjectNameIncludesGitHubID() {
        let name = CodebaseMemoryRunner.projectName(
            owner: "DeusData",
            name: "codebase-memory-mcp",
            githubID: 12345
        )

        #expect(name == "starcat-12345-DeusData-codebase-memory-mcp")
    }

    @Test("UI 启动前必须确认 cache 中的 project root 属于当前 repo")
    func verifiedProjectNameAcceptsCurrentRepoRoot() throws {
        let source = URL(fileURLWithPath: "/tmp/starcat-codebase-memory/owner/repo/source", isDirectory: true)
        let name = try CodebaseMemoryRunner.verifiedProjectName(
            projects: [
                CodebaseMemoryCLIProject(name: "another-project", rootPath: "/tmp/another"),
                CodebaseMemoryCLIProject(name: "tmp-starcat-owner-repo-source", rootPath: source.path)
            ],
            expectedProjectName: "tmp-starcat-owner-repo-source",
            expectedSourceURL: source,
            repositoryFullName: "owner/repo"
        )

        #expect(name == "tmp-starcat-owner-repo-source")
    }

    @Test("UI 启动前发现 cache 指向其他 repo 时必须阻止打开")
    func verifiedProjectNameRejectsDifferentRepoRoot() {
        let current = URL(fileURLWithPath: "/tmp/starcat-codebase-memory/owner-b/repo-b/source", isDirectory: true)
        let previous = URL(fileURLWithPath: "/tmp/starcat-codebase-memory/owner-a/repo-a/source", isDirectory: true)

        #expect(throws: CodebaseMemoryError.self) {
            try CodebaseMemoryRunner.verifiedProjectName(
                projects: [
                    CodebaseMemoryCLIProject(name: "starcat-123-owner-b-repo-b", rootPath: previous.path)
                ],
                expectedProjectName: "starcat-123-owner-b-repo-b",
                expectedSourceURL: current,
                repositoryFullName: "owner-b/repo-b"
            )
        }
    }

    @Test("共享 UI URL 直接定位到当前仓库图谱")
    func graphPageURLCarriesProjectRoute() {
        let url = CodebaseMemoryRunner.graphPageURL(
            port: 19_986,
            projectName: "starcat-123-owner-repo"
        )

        #expect(url.absoluteString == "http://127.0.0.1:19986/?tab=graph&project=starcat-123-owner-repo")
    }

    @Test("ui_port 解析允许前导日志但拒绝越界端口")
    func uiPortParsing() throws {
        let port = try CodebaseMemoryRunner.parseUIPort(
            Data("level=info msg=mem.init\n19986\n".utf8)
        )
        #expect(port == 19_986)
        #expect(throws: CodebaseMemoryError.self) {
            try CodebaseMemoryRunner.parseUIPort(Data("70000\n".utf8))
        }
    }
}
