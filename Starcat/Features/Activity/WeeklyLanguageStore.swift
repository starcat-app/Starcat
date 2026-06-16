//
//  WeeklyLanguageStore.swift
//  Starcat
//
//  Activity / Weekly 三源聚合语言列表状态容器。
//
//  设计约束：
//  - 语言列表来自 weekly 后端 `/api/v1/repos/languages`，与列表数据同源；
//  - 首次进入 Weekly 时懒加载，避免 App 启动期多一次网络请求；
//  - URL / API Key 热更新时清空并允许重拉，避免设置页切服务后仍显示旧后端语言。
//

import Foundation
import Observation

@MainActor
@Observable
final class WeeklyLanguageStore {

    private(set) var aggregates: [TrendingLanguageAggregateDTO] = []
    private(set) var loadState: LoadState = .idle

    enum LoadState: Equatable {
        case idle
        case loading
        case success
        case failed(String)
    }

    /// 后端不可达时的兜底列表。
    ///
    /// 顺序与后端 `/api/v1/repos/languages` SQL 排序一致(dong4j 2026-06-16 调整):
    /// **未分类排第 1 位**,其余按 count desc(兜底数据 count 全为 0,等价于按字母序),
    /// 客户端 picker 会再 prepend `""`「全部」哨兵,所以最终展示:
    /// 全部 → 未分类 → JavaScript → TypeScript → Python → Go → Rust → Swift → Java → Shell。
    static let fallbackList: [TrendingLanguageAggregateDTO] = [
        .init(key: TrendingLanguage.uncategorizedKey, label: "Uncategorized", count: 0),
        .init(key: "JavaScript", label: "JavaScript", count: 0),
        .init(key: "TypeScript", label: "TypeScript", count: 0),
        .init(key: "Python", label: "Python", count: 0),
        .init(key: "Go", label: "Go", count: 0),
        .init(key: "Rust", label: "Rust", count: 0),
        .init(key: "Swift", label: "Swift", count: 0),
        .init(key: "Java", label: "Java", count: 0),
        .init(key: "Shell", label: "Shell", count: 0),
    ]

    private let api: WeeklyAPI
    private var currentLoadTask: Task<Void, Never>?

    init(api: WeeklyAPI) {
        self.api = api
    }

    func reloadIfNeeded() async {
        guard aggregates.isEmpty, loadState != .loading else { return }
        await reload()
    }

    func reload() async {
        currentLoadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            self.loadState = .loading
            do {
                let dtos = try await self.api.fetchLanguages()
                guard !Task.isCancelled else { return }
                if !dtos.isEmpty {
                    self.aggregates = dtos
                }
                self.loadState = .success
            } catch {
                guard !Task.isCancelled else { return }
                self.loadState = .failed(error.localizedDescription)
                AppLog.network.warning(
                    "Weekly languages load failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        currentLoadTask = task
        await task.value
    }

    func invalidate() {
        currentLoadTask?.cancel()
        aggregates = []
        loadState = .idle
    }

    var displayList: [TrendingLanguageAggregateDTO] {
        aggregates.isEmpty ? Self.fallbackList : aggregates
    }
}
