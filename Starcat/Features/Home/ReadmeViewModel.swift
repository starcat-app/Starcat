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
//  - empty：该 repo 没有 README（404）
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

    init(api: ReadmeAPI) {
        self.api = api
    }

    // MARK: - Actions

    /// 加载指定 repo 的 README。
    /// - Parameter repo: 目标仓库；nil 表示重置到 idle
    func load(repo: Repo?) {
        currentTask?.cancel()
        guard let repo else {
            currentRepoId = nil
            state = .idle
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
                let readme = try await self.api.fetchHTML(for: repo)
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
                self.state = .empty
            } catch NetworkError.cancelled {
                // 用户主动切换导致的取消，不当作错误
                return
            } catch {
                guard !Task.isCancelled, self.currentRepoId == requestedId else { return }
                AppLog.network.error("README 加载失败 repo=\(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.state = .error(message: error.localizedDescription)
            }
        }
    }

    /// 重新加载当前 repo（用户点击"重试"时调用）。
    func reload(repo: Repo) {
        // 重新加载视为强制刷新；这里仍走 API，命中 304 时只会刷新 cached_at
        load(repo: repo)
    }

    /// 重置到 idle（视图从 selected → unselected 时调用）。
    func reset() {
        currentTask?.cancel()
        currentRepoId = nil
        state = .idle
    }

    // MARK: - Helpers

    /// 把 readmes.cached_at 的 ISO8601 字符串解析回 Date，便于 UI 格式化显示。
    private static func parseISO8601(_ s: String) -> Date? {
        ISO8601DateFormatter.shared.date(from: s)
    }
}
