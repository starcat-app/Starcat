//
//  ReadmeHandoffTests.swift
//  StarcatTests
//
//  验证 README 交接任务能观察无文档终态，并且不会把缓存刷新误当成新文档。
//

import Foundation
import Testing
@testable import Starcat

/// 直接验证阅读器实际使用的任务身份，不启动 WebKit 或访问网络。
@MainActor
struct ReadmeHandoffTests {
    @Test("加载结束后空结果、登录提示和错误都会触发交接收口")
    func terminalStatesEndWaiting() {
        let pending = key(.loading)
        for state: ReadmeViewModel.LoadState in [.empty, .requiresLogin, .error(message: "offline")] {
            let terminal = key(state)
            #expect(terminal != pending)
            #expect(terminal.phase == .resolved)
        }
        #expect(key(.idle) == pending)
    }

    @Test("范围未对齐时旧 loaded 或终态只能等待当前仓库")
    func staleScopeWaitsForCurrentRepository() {
        for state: ReadmeViewModel.LoadState in [.loaded(html: "old", cachedAt: .distantPast), .empty, .error(message: "old")] {
            let stale = key(state, documentIdentity: "old", isStateStale: true)
            #expect(stale.phase == .waiting)
        }
        #expect(key(.loading, scope: "manage-A") != key(.loading, scope: "manage-B"))
    }

    @Test("同文档缓存时间变化不重播交接，正文或重试身份变化会触发")
    func cacheRefreshPreservesDocumentIdentity() {
        let original = key(.loaded(html: "content", cachedAt: .distantPast), documentIdentity: "A|doc|retry:0")
        let refreshed = key(.loaded(html: "content", cachedAt: .distantFuture), documentIdentity: "A|doc|retry:0")
        let retried = key(.loaded(html: "content", cachedAt: .distantFuture), documentIdentity: "A|doc|retry:1")
        #expect(original == refreshed)
        #expect(original != retried)
        #expect(original != key(.loaded(html: "updated", cachedAt: .distantFuture), documentIdentity: "A|new|retry:0"))
    }

    @Test("快速回切及未就绪文档不会混淆加载与终态")
    func switchingBackRestoresCurrentDocumentKey() {
        let loaded: ReadmeViewModel.LoadState = .loaded(html: "A", cachedAt: .distantPast)
        let first = key(loaded, scope: "manage-A", documentIdentity: "A")
        let waiting = key(.loading, scope: "manage-B")
        let returned = key(loaded, scope: "manage-A", documentIdentity: "A")
        #expect(first != waiting)
        #expect(returned == first)
        #expect(key(loaded).phase == .waiting)
        #expect(key(.error(message: "first")) == key(.error(message: "second")))
    }

    /// 与 View 使用同一构造入口，覆盖异步任务重启所需的范围、阶段及文档身份。
    private func key(_ state: ReadmeViewModel.LoadState, scope: String = "manage-A",
                     documentIdentity: String? = nil, isStateStale: Bool = false) -> ReadmeStateView.HandoffKey {
        ReadmeStateView.HandoffKey(
            scopeIdentity: scope,
            state: state,
            documentIdentity: documentIdentity,
            isStateStale: isStateStale
        )
    }
}
