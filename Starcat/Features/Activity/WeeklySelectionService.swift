//
//  WeeklySelectionService.swift
//  Starcat
//
//  Explore 页 weekly 分类与外围视图（Sidebar / HomeView detail pane）之间共享的
//  小型 UI 状态总线。
//
//  为什么不走 binding 链路：
//  - sidebar 上需要展示"周刊"分类右侧的项目总数（仿 manage Languages 计数徽章），
//    总数只有 WeeklyContentViewModel 跑完 API 才知道；
//  - HomeView 的右侧详情页需要根据当前 weekly 选中项渲染 WeeklyDetailView。
//  这两条信息都跨越了 SidebarView / RepoListView / ExploreView / HomeView 多层视图，
//  逐层 binding 改动面太大；改成单个 @Observable 服务，谁需要就 @Environment 取。
//
//  关键约束：
//  - 仅承载 UI 临时状态，不做持久化、不主动发网络请求；启动时只读取 SQLite bulk meta；
//  - 主线程隔离（`@MainActor`），所有写入都来自 SwiftUI 视图层；
//  - 切换分类 / 退出 Explore Weekly 时由调用方主动 `clearSelection()`，避免详情页停留陈旧数据。
//

import Foundation
import Observation

/// 周刊 UI 共享状态。
///
/// 字段说明见各 `private(set)` 的注释；写入入口故意限定在 `apply...` /
/// `clearSelection` 几个明确方法上，避免外部直接覆写造成"谁都能写"的失控。
@MainActor
@Observable
final class WeeklySelectionService {

    /// 周刊已 enrich 完成的项目总数；后端 API 的 `total` 字段。
    ///
    /// `nil` 表示"尚未拉取过"，sidebar 据此决定是否显示计数徽章。
    private(set) var total: Int?

    /// Explore 页 weekly 分类中当前选中的聚合 feed 项。
    ///
    /// nil → 详情页显示空态；非 nil → HomeView 详情区路由到 `WeeklyDetailView`。
    /// 用户切换非 weekly 分类、切走 Explore 页时，由调用方主动 `clearSelection`。
    private(set) var selectedItem: WeeklyFeedItem?

    /// WeeklyContentViewModel 拉到分页结果后写一次 total。
    ///
    /// 不要在 sidebar 自己再发请求拉 total —— 详情列表既然要拉，复用即可，
    /// 一来省一次 API 调用，二来保证 sidebar 与列表数据口径一致。
    func applyTotal(_ value: Int) {
        total = value
    }

    /// 启动时从 Weekly bulk meta 恢复 sidebar 数量，不需要先创建列表 ViewModel。
    ///
    /// await 期间用户可能已经点击周刊并发布了更新值，因此返回后必须再次检查 `total`，
    /// 避免较旧的启动缓存覆盖刚完成的列表加载结果。
    func restoreCachedTotal(from repository: any WeeklyBulkRepositoryProtocol) async {
        guard total == nil else { return }
        guard let cachedTotal = await repository.cachedTotal() else { return }
        guard total == nil else { return }
        total = cachedTotal
    }

    /// 选中项目（点击行触发）。
    func select(_ item: WeeklyFeedItem?) {
        selectedItem = item
    }

    /// 清空选中（切换分类、切走 Activity 页时调用）。
    func clearSelection() {
        selectedItem = nil
    }
}
