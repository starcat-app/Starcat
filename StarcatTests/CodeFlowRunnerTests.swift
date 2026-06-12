//
//  CodeFlowRunnerTests.swift
//  StarcatTests
//
//  验证 CodeFlow 集成最关键的 Git clone 命令契约。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CodeFlowRunner")
struct CodeFlowRunnerTests {
    @Test("生成页面会注入源码并移除占位 token")
    func generatedPageContainsInjectedProject() throws {
        let fileManager = FileManager.default
        let sourceURL = fileManager.temporaryDirectory
            .appendingPathComponent("starcat-codeflow-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try "struct Demo {}".write(
            to: sourceURL.appendingPathComponent("Demo.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: sourceURL) }

        let owner = "starcat-page-test-\(UUID().uuidString)"
        let runner = CodeFlowRunner(fileManager: fileManager)
        let pageURL = try runner.makeVisualizationPage(
            repositoryURL: sourceURL,
            owner: owner,
            name: "Demo"
        )
        defer { try? fileManager.removeItem(at: pageURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let html = try String(contentsOf: pageURL, encoding: .utf8)
        #expect(!html.contains("__STARCAT_CODEFLOW_PAYLOAD_TOKEN__"))
        #expect(html.contains("window.__STARCAT_CODEFLOW_PROJECT_BASE64__ = \""))
    }

    @Test("clone 使用系统 Git 和 shallow clone")
    func cloneCommand() async throws {
        let executor = RecordingCodeFlowExecutor()
        let fileManager = FileManager.default
        let runner = CodeFlowRunner(executor: executor, fileManager: fileManager)
        let owner = "starcat-test-\(UUID().uuidString)"
        let destination = try runner.repositoryDirectory(owner: owner, name: "codeflow")
        try? fileManager.removeItem(at: destination)
        defer { try? fileManager.removeItem(at: destination.deletingLastPathComponent()) }

        let repo = Repo(
            id: 99_001,
            owner: owner,
            name: "codeflow",
            fullName: "\(owner)/codeflow",
            description: nil,
            language: "HTML",
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: "MIT",
            homepage: nil,
            htmlUrl: "https://github.com/braedonsaunders/codeflow",
            cloneUrl: "https://github.com/braedonsaunders/codeflow.git",
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
        _ = try await runner.cloneIfNeeded(repo: repo)

        let calls = await executor.calls
        #expect(calls.count == 1)
        #expect(calls[0].executableURL.path == "/usr/bin/git")
        #expect(calls[0].arguments == [
            "clone", "--depth=1", "https://github.com/braedonsaunders/codeflow.git", destination.path
        ])
    }
}

private actor RecordingCodeFlowExecutor: CodeFlowCommandExecuting {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []

    func run(executableURL: URL, arguments: [String]) async throws -> CodeFlowCommandResult {
        calls.append(Call(executableURL: executableURL, arguments: arguments))
        return CodeFlowCommandResult(
            executable: executableURL.path,
            arguments: arguments,
            exitCode: 0,
            stdout: "ok",
            stderr: ""
        )
    }
}
