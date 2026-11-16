//
//  RepositoryMarkdownNavigationTests.swift
//  StarcatTests
//
//  验证当前阅读区文档替换、失败恢复与异步取消，不访问网络或启动 WebKit。
//

import Foundation
import Testing
@testable import Starcat

/// 使用可控响应重现快速点击、返回 README 与切换账号时的迟到结果。
@MainActor
struct RepositoryMarkdownNavigationTests {
    @Test("链接文档发布路径、基址与正文，返回后恢复根 README")
    func opensDocumentAndReturnsToReadme() async {
        let model = RepositoryMarkdownNavigation()
        let target = target("docs/README.zh.md")
        await model.open(target, scopeIdentity: "repo-A") { _ in "<p>中文</p>" }.value
        #expect(model.document?.target == target)
        #expect(model.document?.html == "<p>中文</p>")
        #expect(model.document?.target.contentBaseURL.absoluteString == "https://github.com/alice/foo/blob/main/docs/")
        #expect(!model.isLoading)
        model.reset(scopeIdentity: "repo-A")
        #expect(model.document == nil)
        #expect(!model.isLoading)
    }

    @Test("加载失败保留上一份文档，首次失败仍能回到根 README")
    func failureRetainsPreviousDocument() async {
        let model = RepositoryMarkdownNavigation()
        await model.open(target("README.zh.md"), scopeIdentity: "repo-A") { _ in "previous" }.value
        let identity = model.document?.identity
        await model.open(target("missing.md"), scopeIdentity: "repo-A") { _ in
            throw URLError(.fileDoesNotExist)
        }.value
        #expect(model.document?.identity == identity)
        #expect(model.document?.html == "previous")
        #expect(model.errorMessage == "readme.failed")
        #expect(!model.isLoading)

        model.reset(scopeIdentity: "repo-A")
        await model.open(target("missing.md"), scopeIdentity: "repo-A") { _ in
            throw URLError(.notConnectedToInternet)
        }.value
        #expect(model.document == nil)
        #expect(!model.isLoading)
        #expect(model.errorMessage != nil)
    }

    @Test("快速点击后较早请求迟到也不能覆盖最终文档")
    func latestRequestWins() async {
        let model = RepositoryMarkdownNavigation()
        let delayed = MarkdownResponseGate()
        let first = model.open(target("first.md"), scopeIdentity: "repo-A") { _ in
            try await delayed.load()
        }
        await delayed.waitUntilStarted()
        await model.open(target("last.md"), scopeIdentity: "repo-A") { _ in "last" }.value
        delayed.finish("first")
        await first.value
        #expect(model.document?.target.path == "last.md")
        #expect(model.document?.html == "last")
        #expect(model.errorMessage == nil)
    }

    @Test("刷新已有文档时保留正文，不重新显示整页骨架")
    func refreshingPreservesVisibleDocument() async {
        let model = RepositoryMarkdownNavigation()
        let target = target("README.zh.md")
        await model.open(target, scopeIdentity: "repo-A") { _ in "cached" }.value
        let delayed = MarkdownResponseGate()
        let refreshing = model.open(target, scopeIdentity: "repo-A", preservingDocument: true) { _ in
            try await delayed.load()
        }
        await delayed.waitUntilStarted()
        #expect(model.isRefreshing)
        #expect(!model.isLoading)
        #expect(model.document?.html == "cached")
        delayed.finish("fresh")
        await refreshing.value
        #expect(model.document?.html == "fresh")
        #expect(!model.isRefreshing)
    }

    @Test("返回或切仓取消请求，即使返回原仓库也不接受旧响应")
    func scopeResetRejectsLateResponses() async {
        for destination in ["repo-A", "repo-B", "repo-A|account-B"] {
            let model = RepositoryMarkdownNavigation()
            let delayed = MarkdownResponseGate()
            let pending = model.open(target("old.md"), scopeIdentity: "repo-A") { _ in
                try await delayed.load()
            }
            await delayed.waitUntilStarted()
            model.reset(scopeIdentity: destination)
            delayed.finish("old")
            await pending.value
            #expect(model.scopeIdentity == destination)
            #expect(model.document == nil)
            #expect(!model.isLoading)
        }
    }

    /// 明确使用嵌套路径与固定 ref，覆盖继续阅读时必须保留的文档定位。
    private func target(_ path: String) -> RepositoryMarkdownLinkTarget {
        RepositoryMarkdownLinkTarget(owner: "alice", repo: "foo", ref: "main", path: path)
    }
}

/// 模拟不响应 Task 取消的网络结果；用握手等待代替 sleep，保证迟到场景可重复。
@MainActor
private final class MarkdownResponseGate {
    private var response: CheckedContinuation<String, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func load() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        guard response == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ html: String) {
        response?.resume(returning: html)
        response = nil
    }
}
