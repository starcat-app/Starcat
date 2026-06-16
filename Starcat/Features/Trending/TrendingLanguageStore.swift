//
//  TrendingLanguageStore.swift
//  Starcat
//
//  trending sidebar 语言列表的状态容器（2026-06-11 dong4j 新增）。
//
//  用途：
//  - 在 App 启动 / Home 页面进入时拉取后端 `/api/v1/languages`（聚合接口）
//  - 把结果缓存为 [TrendingLanguageAggregateDTO]，供 SidebarView 驱动 trending 语言列表
//  - 后端返空 / 不可达时退化到 `fallbackList`，保证 sidebar 始终能展示一组语言入口
//
//  历史背景（已踩过的坑）：
//  - SidebarView 的 `trendingLanguages` 之前从 `HomeViewModel.languageStats`（用户本地 stars 聚合）
//    读，与 trending 后端**实际是否有这些语言的 repo** 完全脱钩——用户是 Swift 开发者但本周
//    trending 一个 Swift 都没有时，sidebar 仍展示 Swift，点进去 0 条数据。
//  - 后端 `/api/v1/languages` v1（爬 GitHub trending 页面）返 700+ 全量语言菜单，绝大多数语言
//    在我们库里没数据。前端如果直接用，问题更严重。
//  - 改造：后端 v2 改基于 trending_repos 实际数据聚合 + 加 `__uncategorized__` 一项；前端切
//    sidebar 数据源到本 Store。
//
//  设计约束：
//  - @MainActor + @Observable：sidebar 直接观察 `aggregates` 变化自动重渲染
//  - 不持有 GRDB writer / cache 表：trending 语言列表是「站内统一视图」，所有客户端从同一个
//    后端 endpoint 拿；本地不再缓存（后端响应通常 < 5KB，每次启动拉一次开销可忽略）
//  - 失败兜底：保留 `fallbackList` 让 sidebar 在以下三种情况都有可探索的入口：
//      ① 后端不可达（用户离线 / 后端宕机）
//      ② 后端返空（trending_repos 表暂时没数据，比如冷启动）
//      ③ Bearer Auth 配置错误（用户没填 / 填错 API Key）
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TrendingLanguageStore {

    // MARK: - 状态

    /// 当前后端聚合结果(dong4j 2026-06-16 调整: **未分类排第 1 位**, 其余按 count DESC 排好;
    /// 空数组 = 还未拉到 / 后端返空)。
    ///
    /// SidebarView 直接 ForEach 这个数组，转换成 `TrendingLanguage` row 渲染。
    /// 数组**不**包含 `.all`——「全部语言」是 sidebar 的固定首行，由 view 层独立渲染。
    private(set) var aggregates: [TrendingLanguageAggregateDTO] = []

    /// 最近一次拉取的状态，UI 可以观察决定是否显示加载指示。
    /// 当前 sidebar 的语言区域不显示 loader（列表很短，几乎瞬间到货 + 有 fallback 兜底），
    /// 仅作 debug / 未来扩展用。
    private(set) var loadState: LoadState = .idle

    enum LoadState: Equatable {
        case idle
        case loading
        case success
        case failed(String)
    }

    // MARK: - 兜底列表

    /// 后端不可达 / 返空时使用的兜底语言列表。
    ///
    /// 选用与 GitHub Linguist top languages 高度重合的一组常见语言；count 字段填 0
    /// 让 sidebar 行尾不显示数字（与「真聚合且 count > 0」的视觉差异由 view 层决定是否展示 count）。
    ///
    /// 顺序与后端 `/api/v1/languages` SQL 排序一致(dong4j 2026-06-16 调整):
    /// **未分类排第 1 位**, 其余按 count desc(兜底数据 count 全为 0,等价于按字母序)。
    /// SidebarView 已经把「全部」作为 sidebar 的固定首行独立渲染,本数组不再 prepend `.all`。
    static let fallbackList: [TrendingLanguageAggregateDTO] = [
        .init(key: TrendingLanguage.uncategorizedKey,
              label: "Uncategorized",
              count: 0),
        .init(key: "JavaScript", label: "JavaScript", count: 0),
        .init(key: "TypeScript", label: "TypeScript", count: 0),
        .init(key: "Python", label: "Python", count: 0),
        .init(key: "Go", label: "Go", count: 0),
        .init(key: "Rust", label: "Rust", count: 0),
        .init(key: "Java", label: "Java", count: 0),
        .init(key: "Swift", label: "Swift", count: 0),
        .init(key: "C++", label: "C++", count: 0),
        .init(key: "C", label: "C", count: 0),
        .init(key: "Shell", label: "Shell", count: 0),
    ]

    // MARK: - 依赖

    private let api: TrendingAPI

    /// 当前 in-flight 的拉取任务，新调进来取消老任务避免 race（同 `TrendingViewModel.reload` 模式）。
    private var currentLoadTask: Task<Void, Never>?

    // MARK: - Init

    init(api: TrendingAPI) {
        self.api = api
    }

    // MARK: - Public API

    /// 拉取后端聚合语言列表并更新 `aggregates`。
    ///
    /// 调用时机：
    /// - HomeView 首次进入时（`task` modifier）
    /// - 用户在设置页改 baseURL / API Key 后（AppDependencies 主动调）
    /// - 切换页面到 trending（可选，当前不做——首屏拿到一次就够，后端数据 24h 内变化频度低）
    ///
    /// 行为：
    /// - 拉成功且 data 非空 → 写入 `aggregates`、状态 `.success`
    /// - 拉成功但 data 空 → 不写入（保留上次结果或空），状态 `.success`，
    ///   sidebar 看到 aggregates 仍空时自动走 fallbackList 兜底
    /// - 拉失败（网络 / 401 / 解码）→ 不动 `aggregates`、状态 `.failed`，
    ///   日志记录 error description；UI 由调用方决定是否提示
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
                AppLog.network.debug("Trending languages loaded: \(dtos.count) entries")
            } catch {
                guard !Task.isCancelled else { return }
                self.loadState = .failed(error.localizedDescription)
                AppLog.network.warning(
                    "Trending languages load failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        currentLoadTask = task
        await task.value
    }

    /// SidebarView 实际使用的「展示用」数组。
    ///
    /// 优先返回真实聚合结果；空（首次进入还没拉到 / 后端返空 / 拉失败）时返回 `fallbackList`。
    /// 这样把「兜底逻辑」收敛在 store 一处，sidebar 直接 ForEach 这个属性，无需关心数据来源。
    var displayList: [TrendingLanguageAggregateDTO] {
        aggregates.isEmpty ? Self.fallbackList : aggregates
    }
}
