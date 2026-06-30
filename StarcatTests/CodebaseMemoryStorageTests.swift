//
//  CodebaseMemoryStorageTests.swift
//  StarcatTests
//
//  验证 CodebaseMemory 的本地目录约束，避免多个 repo 共用同一个 graph/config cache。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CodebaseMemoryStorage")
@MainActor
struct CodebaseMemoryStorageTests {

    @Test("每个 repo 使用独立 internal cache，避免浏览器 UI 复用上一个项目状态")
    func projectCacheDirectoryIsRepoScoped() {
        let root = URL(fileURLWithPath: "/tmp/starcat-codebase-memory", isDirectory: true)
        let storage = CodebaseMemoryStorage(fileManager: .default, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let cacheA = storage.projectCacheDirectory(root: root, owner: "owner-a", name: "repo")
        let cacheB = storage.projectCacheDirectory(root: root, owner: "owner-b", name: "repo")

        #expect(cacheA == root.appendingPathComponent("owner-a/repo/.internal-cache", isDirectory: true))
        #expect(cacheB == root.appendingPathComponent("owner-b/repo/.internal-cache", isDirectory: true))
        #expect(cacheA != cacheB)
        #expect(cacheA != root.appendingPathComponent(".internal-cache", isDirectory: true))
    }

    @Test("UI 启动前必须确认 cache 中的 project root 属于当前 repo")
    func verifiedProjectNameAcceptsCurrentRepoRoot() throws {
        let source = URL(fileURLWithPath: "/tmp/starcat-codebase-memory/owner/repo/source", isDirectory: true)
        let name = try CodebaseMemoryRunner.verifiedProjectName(
            projects: [
                CodebaseMemoryCLIProject(name: "tmp-starcat-owner-repo-source", rootPath: source.path)
            ],
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
                    CodebaseMemoryCLIProject(name: "tmp-starcat-owner-a-repo-a-source", rootPath: previous.path)
                ],
                expectedSourceURL: current,
                repositoryFullName: "owner-b/repo-b"
            )
        }
    }
}
