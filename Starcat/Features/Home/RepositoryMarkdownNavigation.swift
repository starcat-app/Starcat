//
//  RepositoryMarkdownNavigation.swift
//  Starcat
//
//  当前阅读区的同仓 Markdown 会话。只保存临时文档，不覆盖默认 README 缓存。
//

import Foundation
import Observation

/// 阅读器内的文档导航；仓库或账号范围变化、返回 README 时取消未完成请求。
@MainActor
@Observable
final class RepositoryMarkdownNavigation {
    /// HTML 与路径作为同一份快照发布，避免旧正文提前使用新文档的基址。
    struct Document {
        let target: RepositoryMarkdownLinkTarget
        let html: String
        let loadedAt: Date
        let identity = UUID().uuidString
    }

    private(set) var scopeIdentity: String?
    private(set) var document: Document?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    var errorMessage: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var requestRevision = 0

    /// 点击即开始准备新文档；视图独立完成退场，真正替换 DOM 前仍须等待退场结束。
    /// 返回任务供单测等待，不让视图依赖网络是否立即响应。
    @discardableResult
    func open(
        _ target: RepositoryMarkdownLinkTarget,
        scopeIdentity: String,
        preservingDocument: Bool = false,
        load: @escaping @MainActor (RepositoryMarkdownLinkTarget) async throws -> String
    ) -> Task<Void, Never> {
        if self.scopeIdentity != scopeIdentity {
            reset(scopeIdentity: scopeIdentity)
        }
        loadTask?.cancel()
        requestRevision += 1
        let revision = requestRevision
        isLoading = !preservingDocument || document == nil
        isRefreshing = true
        errorMessage = nil

        let task = Task { @MainActor in
            do {
                let html = try await load(target)
                // 取消并不保证底层请求立刻退出；快速换文档和切仓后只允许最后一次请求发布。
                guard !Task.isCancelled, revision == requestRevision else { return }
                document = Document(target: target, html: html, loadedAt: Date())
                isLoading = false
                isRefreshing = false
            } catch {
                guard !Task.isCancelled, revision == requestRevision else { return }
                // 保留上一份文档（或原始 README）；失败不会把阅读区留在永久骨架。
                isLoading = false
                isRefreshing = false
                errorMessage = "readme.failed"
                AppLog.ui.error("Repository markdown navigation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        loadTask = task
        return task
    }

    /// 返回根文档与切换范围使用同一取消入口，迟到结果不能把旧文档重新上屏。
    func reset(scopeIdentity: String) {
        loadTask?.cancel()
        loadTask = nil
        requestRevision += 1
        self.scopeIdentity = scopeIdentity
        document = nil
        isLoading = false
        isRefreshing = false
        errorMessage = nil
    }
}
