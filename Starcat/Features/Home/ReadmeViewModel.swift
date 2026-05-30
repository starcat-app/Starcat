//
//  ReadmeViewModel.swift
//  Starcat
//
//  README 详情视图的 ViewModel。
//
//  状态机：
//  - idle：尚未加载（初始态或重置后）
//  - loading：正在请求
//  - loaded(html, cachedAt)：已加载并准备渲染
//  - empty：该 repo 没有 README（404 或本地 session 缓存的"已知 404"）
//  - error(message)：网络或解析错误
//
//  生命周期：
//  - RepoDetailView 在 selectedRepo 变化时调用 load(repo:)
//  - 切换 repo 时旧任务自动取消（避免 race condition 导致显示错配）
//  - 视图离开 / nil repo 时调用 reset() 释放状态
//
//  设计约束：
//  - @MainActor：所有状态写入都在主线程，避免 SwiftUI 触发警告
//  - 把 Task 自身存起来，新请求来时 cancel 旧任务；不依赖 view 的 task(id:) 因为我们要更细的取消粒度
//
//  Session 404 缓存（Phase 1，2026-05-30）：
//  - `sessionNotFound: Set<Int64>` 记录 session 内已确认无 README 的 repoId
//  - 用户反复点同一个无 README 仓库时直接走 empty 态，不再请求 GitHub
//  - 仅在 ViewModel 实例生命周期内有效；app 冷启动重新尝试一次
//    （README 可能被作者补上，且 GitHub Rate Limit 每小时重置）
//  - 用户主动 reload 时清掉对应 repoId，给一次"重试"机会
//

import Foundation

@MainActor
@Observable
final class ReadmeViewModel {

    /// 加载状态。
    enum LoadState: Equatable {
        case idle
        case loading
        /// `cachedAt`：本地缓存写入时间，UI 可显示"上次更新于..."
        case loaded(html: String, cachedAt: Date)
        case empty
        case error(message: String)
    }

    private(set) var state: LoadState = .idle

    private let api: ReadmeAPI

    /// 当前加载中的 repoId，用于"切换 repo 时丢弃旧响应"。
    /// race 场景：先点 repo A → loading；快速切到 repo B → loading；
    /// A 的响应晚于 B 到达 → 必须丢弃 A 的写状态。
    private var currentRepoId: Int64?

    /// 当前 in-flight 任务。新请求来时先 cancel。
    private var currentTask: Task<Void, Never>?

    /// session 内已确认"无 README"（404）的 repoId 集合。
    /// 防止用户反复点同一个无 README 仓库时浪费 GitHub Rate Limit。
    /// - 自动加载（`load(repo:)`）命中 → 直接 empty 不请求
    /// - 手动刷新（`reload(repo:)`）会清掉对应项，给一次重试机会
    private var sessionNotFound: Set<Int64> = []

    init(api: ReadmeAPI) {
        self.api = api
    }

    // MARK: - Actions

    /// 加载指定 repo 的 README。
    /// - Parameter repo: 目标仓库；nil 表示重置到 idle
    func load(repo: Repo?) {
        loadInternal(repo: repo, forceRefresh: false)
    }

    /// 重新加载当前 repo（用户点击"重试" / 详情底栏"刷新"时调用）。
    ///
    /// 与 `load(repo:)` 的差异：
    /// - 清掉 sessionNotFound 中该 repoId（给一次重试机会，README 可能刚被作者补上）
    /// - `forceRefresh: true` 绕过 ReadmeAPI 的 softTtl 短路，强制走条件请求
    /// - 命中 304 时只会刷新 cached_at；命中 200 时整体覆盖写入
    func reload(repo: Repo) {
        loadInternal(repo: repo, forceRefresh: true)
    }

    /// 重置到 idle（视图从 selected → unselected 时调用）。
    func reset() {
        currentTask?.cancel()
        currentRepoId = nil
        state = .idle
    }

    // MARK: - 内部

    /// load / reload 的统一实现。
    ///
    /// 通过 `forceRefresh` 区分两种意图：
    /// - false（自动加载）：受 sessionNotFound 与 softTtl 双重短路保护
    /// - true（用户主动刷新）：清掉 sessionNotFound，绕过 softTtl
    private func loadInternal(repo: Repo?, forceRefresh: Bool) {
        currentTask?.cancel()
        guard let repo else {
            currentRepoId = nil
            state = .idle
            return
        }

        // session 404 缓存：仅自动加载受其影响；手动 reload 会清掉
        if forceRefresh {
            sessionNotFound.remove(repo.id)
        } else if sessionNotFound.contains(repo.id) {
            currentRepoId = repo.id
            state = .empty
            return
        }

        // 切到新 repo 且不是同一个 → 重置加载态
        if currentRepoId != repo.id {
            state = .loading
        } else if case .idle = state {
            state = .loading
        }

        currentRepoId = repo.id
        let requestedId = repo.id

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let readme = try await self.api.fetchHTML(for: repo, forceRefresh: forceRefresh)
                // 旧请求晚到 → 丢弃
                guard !Task.isCancelled, self.currentRepoId == requestedId else { return }

                if let html = readme.renderedHtml, !html.isEmpty {
                    let cachedAt = Self.parseISO8601(readme.cachedAt) ?? Date()
                    self.state = .loaded(html: html, cachedAt: cachedAt)
                } else {
                    self.state = .empty
                }
            } catch NetworkError.notFound {
                guard !Task.isCancelled, self.currentRepoId == requestedId else { return }
                // 缓存 404 到 session，下次同一 repo 自动加载时直接走 empty
                self.sessionNotFound.insert(requestedId)
                self.state = .empty
            } catch NetworkError.cancelled {
                // 用户主动切换导致的取消，不当作错误
                return
            } catch {
                guard !Task.isCancelled, self.currentRepoId == requestedId else { return }
                AppLog.network.error("README 加载失败 repo=\(repo.fullName, privacy: .public) force=\(forceRefresh, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.state = .error(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    /// 把 readmes.cached_at 的 ISO8601 字符串解析回 Date，便于 UI 格式化显示。
    private static func parseISO8601(_ s: String) -> Date? {
        ISO8601DateFormatter.shared.date(from: s)
    }
}
